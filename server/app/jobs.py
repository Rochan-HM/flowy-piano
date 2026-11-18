"""In-memory job queue: a fixed number of worker threads, each running one page at a time."""

from __future__ import annotations

import logging
import queue
import shutil
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from .config import Settings
from .engine import EngineError
from .inputs import Page
from .musicxml import merge_pages, score_warnings, summarize

log = logging.getLogger("omr.jobs")

QUEUED, RUNNING, SUCCEEDED, FAILED, CANCELED = "queued", "running", "succeeded", "failed", "canceled"
FINISHED = (SUCCEEDED, FAILED, CANCELED)


class QueueFull(Exception):
    pass


def _iso(ts: float | None) -> str | None:
    return datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="seconds") if ts else None


@dataclass
class Job:
    id: str
    dir: Path
    pages: list[Page]
    inputs: list[dict]
    status: str = QUEUED
    created: float = field(default_factory=time.time)
    started: float | None = None
    finished: float | None = None
    page_results: list[dict] = field(default_factory=list)
    warnings: list[dict] = field(default_factory=list)
    summary: dict | None = None
    error: dict | None = None
    musicxml: Path | None = None
    done: threading.Event = field(default_factory=threading.Event)


class JobManager:
    def __init__(self, settings: Settings, engine) -> None:
        self.settings = settings
        self.engine = engine
        self.jobs: dict[str, Job] = {}
        self.lock = threading.Lock()
        self.queue: queue.Queue[str] = queue.Queue()
        self.stopping = threading.Event()
        self.threads: list[threading.Thread] = []

    def start(self) -> None:
        self.settings.work_dir.mkdir(parents=True, exist_ok=True)
        for i in range(self.settings.workers):
            t = threading.Thread(target=self._worker, name=f"omr-worker-{i}", daemon=True)
            t.start()
            self.threads.append(t)
        t = threading.Thread(target=self._janitor, name="omr-janitor", daemon=True)
        t.start()
        self.threads.append(t)

    def stop(self) -> None:
        self.stopping.set()

    def new_job_dir(self) -> tuple[str, Path]:
        job_id = uuid.uuid4().hex
        d = self.settings.work_dir / job_id
        d.mkdir(parents=True)
        return job_id, d

    def submit(self, job_id: str, job_dir: Path, pages: list[Page], inputs: list[dict]) -> Job:
        with self.lock:
            queued = sum(1 for j in self.jobs.values() if j.status == QUEUED)
            if queued >= self.settings.max_queued_jobs:
                raise QueueFull()
            job = Job(id=job_id, dir=job_dir, pages=pages, inputs=inputs)
            self.jobs[job_id] = job
        self.queue.put(job_id)
        return job

    def get(self, job_id: str) -> Job | None:
        with self.lock:
            return self.jobs.get(job_id)

    def cancel(self, job_id: str) -> bool:
        with self.lock:
            job = self.jobs.pop(job_id, None)
        if job is None:
            return False
        if job.status not in FINISHED:
            job.status = CANCELED
            job.finished = time.time()
            job.done.set()
        shutil.rmtree(job.dir, ignore_errors=True)
        return True

    def counts(self) -> dict:
        with self.lock:
            statuses = [j.status for j in self.jobs.values()]
        return {"queued": statuses.count(QUEUED), "running": statuses.count(RUNNING)}

    def queue_position(self, job: Job) -> int | None:
        if job.status != QUEUED:
            return None
        with self.lock:
            ahead = [j for j in self.jobs.values() if j.status == QUEUED and j.created < job.created]
        return len(ahead)

    def _worker(self) -> None:
        while not self.stopping.is_set():
            try:
                job_id = self.queue.get(timeout=0.5)
            except queue.Empty:
                continue
            job = self.get(job_id)
            if job is None or job.status != QUEUED:
                continue
            try:
                self._run(job)
            except Exception as e:  # noqa: BLE001 - a job must never kill its worker
                log.exception("job %s crashed", job.id)
                job.status = FAILED
                job.error = {"code": "internal_error", "message": str(e)}
            finally:
                if job.finished is None:
                    job.finished = time.time()
                job.done.set()

    def _run(self, job: Job) -> None:
        job.status = RUNNING
        job.started = time.time()
        outputs: list[Path] = []
        for i, page in enumerate(job.pages, start=1):
            if job.status == CANCELED:
                return
            t0 = time.time()
            result = {"page": i, "source": page.source, "warnings": list(page.warnings)}
            try:
                xml = self.engine.recognize_page(page.path, self.settings.page_timeout_s)
                s = summarize(xml)
                result.update(status="ok", staves=s["staff_count"], measures=s["measure_count"], notes=s["note_count"])
                if s["measure_count"] == 0:
                    result["status"] = "empty"
                    result["warnings"].append({"code": "no_music_found", "message": "no staves or measures found"})
                else:
                    outputs.append(xml)
            except EngineError as e:
                result.update(status="failed")
                result["warnings"].append({"code": "page_failed", "message": str(e)})
            result["seconds"] = round(time.time() - t0, 1)
            job.page_results.append(result)
            for w in result["warnings"]:
                job.warnings.append({**w, "page": i})
        if job.status == CANCELED:
            return
        if not outputs:
            job.status = FAILED
            job.error = {"code": "recognition_failed", "message": "no music was recognized on any page"}
            return
        merged = job.dir / "score.musicxml"
        if len(outputs) == 1:
            shutil.copy(outputs[0], merged)
        else:
            job.warnings += merge_pages(outputs, merged)
        job.summary = summarize(merged)
        job.warnings += score_warnings(job.summary, engine_reads_fingering=self.engine.supports_fingering)
        job.musicxml = merged
        job.status = SUCCEEDED
        job.finished = time.time()

    def _janitor(self) -> None:
        while not self.stopping.wait(30):
            cutoff = time.time() - self.settings.job_ttl_s
            with self.lock:
                expired = [j for j in self.jobs.values() if j.status in FINISHED and (j.finished or 0) < cutoff]
                for j in expired:
                    del self.jobs[j.id]
            for j in expired:
                shutil.rmtree(j.dir, ignore_errors=True)

    def to_json(self, job: Job) -> dict:
        return {
            "id": job.id,
            "status": job.status,
            "created_at": _iso(job.created),
            "started_at": _iso(job.started),
            "finished_at": _iso(job.finished),
            "queue_position": self.queue_position(job),
            "progress": {"pages_done": len(job.page_results), "pages_total": len(job.pages)},
            "inputs": job.inputs,
            "pages": job.page_results,
            "result": job.summary,
            "warnings": job.warnings,
            "error": job.error,
            "musicxml_url": f"/v1/jobs/{job.id}/musicxml" if job.status == SUCCEEDED else None,
            "engine": {"name": self.engine.name, "version": self.engine.version},
        }
