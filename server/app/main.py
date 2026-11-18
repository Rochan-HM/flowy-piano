"""HTTP API: upload sheet music (images or PDF), poll the job, download MusicXML."""

from __future__ import annotations

import asyncio
import logging
import os
import secrets
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, File, Header, HTTPException, Query, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, JSONResponse, Response

from .config import Settings, load_settings
from .engine import create_engine
from .inputs import HEIF_SUPPORTED, InputError, prepare_pages
from .jobs import FINISHED, SUCCEEDED, JobManager, QueueFull

log = logging.getLogger("omr")
MAX_WAIT_S = 30


class ApiError(HTTPException):
    def __init__(self, status: int, code: str, message: str, headers: dict | None = None) -> None:
        super().__init__(status, {"code": code, "message": message}, headers=headers)


class UploadLimit:
    """Rejects request bodies over the limit while they stream in, before multipart parsing buffers them."""

    def __init__(self, app, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] != "POST":
            return await self.app(scope, receive, send)
        headers = dict(scope.get("headers") or [])
        length = headers.get(b"content-length")
        if length is not None and length.isdigit() and int(length) > self.max_bytes:
            return await self._reject(send)
        seen = 0

        async def limited_receive():
            nonlocal seen
            message = await receive()
            if message["type"] == "http.request":
                seen += len(message.get("body", b""))
                if seen > self.max_bytes:
                    raise _TooLarge()
            return message

        try:
            await self.app(scope, limited_receive, send)
        except _TooLarge:
            await self._reject(send)

    async def _reject(self, send):
        mb = self.max_bytes // (1024 * 1024)
        resp = JSONResponse(
            {"error": {"code": "upload_too_large", "message": f"upload exceeds {mb} MB"}}, status_code=413
        )
        await resp({"type": "http"}, None, send)


class _TooLarge(Exception):
    pass


def create_app(settings: Settings | None = None, engine=None) -> FastAPI:
    settings = settings or load_settings()
    if not settings.api_token and os.environ.get("OMR_ALLOW_NO_AUTH") != "1":
        raise RuntimeError("set OMR_API_TOKEN (or OMR_ALLOW_NO_AUTH=1 for local development)")
    engine = engine or create_engine(settings.engine)
    manager = JobManager(settings, engine)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        manager.start()
        yield
        manager.stop()

    app = FastAPI(title="flowy-piano OMR server", version="1.0.0", lifespan=lifespan)
    app.state.manager = manager
    # multipart framing adds a little on top of the files themselves
    app.add_middleware(UploadLimit, max_bytes=settings.max_upload_bytes + 256 * 1024)

    @app.exception_handler(HTTPException)
    async def http_error(_: Request, exc: HTTPException):
        detail = exc.detail if isinstance(exc.detail, dict) else {"code": "http_error", "message": str(exc.detail)}
        return JSONResponse({"error": detail}, status_code=exc.status_code, headers=exc.headers)

    def require_token(authorization: str | None = Header(default=None)) -> None:
        if not settings.api_token:
            return
        scheme, _, token = (authorization or "").partition(" ")
        if scheme.lower() != "bearer" or not secrets.compare_digest(token.strip(), settings.api_token):
            raise ApiError(401, "unauthorized", "missing or invalid bearer token", {"WWW-Authenticate": "Bearer"})

    async def wait_for(job, wait: float) -> None:
        deadline = asyncio.get_running_loop().time() + min(wait, MAX_WAIT_S)
        while job.status not in FINISHED and asyncio.get_running_loop().time() < deadline:
            await asyncio.sleep(0.25)

    def job_or_404(job_id: str):
        job = manager.get(job_id)
        if job is None:
            raise ApiError(404, "job_not_found", "no such job (finished jobs expire)")
        return job

    @app.get("/healthz")
    def healthz():
        return {
            "status": "ok" if engine.ready() else "degraded",
            "engine": {"name": engine.name, "version": engine.version, "reads_fingering": engine.supports_fingering},
            "jobs": manager.counts(),
            "limits": {
                "max_upload_mb": settings.max_upload_mb,
                "max_pages": settings.max_pdf_pages,
                "max_image_megapixels": settings.max_image_megapixels,
                "accepted": ["application/pdf", "image/jpeg", "image/png", "image/tiff", "image/webp"]
                + (["image/heic"] if HEIF_SUPPORTED else []),
            },
        }

    @app.post("/v1/jobs", dependencies=[Depends(require_token)])
    async def create_job(
        file: list[UploadFile] = File(..., description="One PDF and/or images, in page order"),
        wait: float = Query(0, ge=0, le=MAX_WAIT_S, description="Seconds to wait for the result"),
    ):
        files = []
        total = 0
        for f in file:
            data = await f.read()
            total += len(data)
            if total > settings.max_upload_bytes:
                raise ApiError(413, "upload_too_large", f"upload exceeds {settings.max_upload_mb} MB")
            files.append((f.filename or "upload", data))
        job_id, job_dir = manager.new_job_dir()
        try:
            pages = await run_in_threadpool(
                prepare_pages,
                files,
                job_dir / "pages",
                dpi=settings.pdf_dpi,
                max_pages=settings.max_pdf_pages,
                max_megapixels=settings.max_image_megapixels,
            )
            inputs = [{"filename": name, "bytes": len(data)} for name, data in files]
            job = manager.submit(job_id, job_dir, pages, inputs)
        except InputError as e:
            await run_in_threadpool(_rmtree, job_dir)
            raise ApiError(e.status, e.code, e.message) from e
        except QueueFull as e:
            await run_in_threadpool(_rmtree, job_dir)
            raise ApiError(429, "queue_full", "too many jobs waiting; retry later", {"Retry-After": "30"}) from e
        if wait:
            await wait_for(job, wait)
        status = 200 if job.status in FINISHED else 202
        return JSONResponse(manager.to_json(job), status_code=status, headers={"Location": f"/v1/jobs/{job.id}"})

    @app.get("/v1/jobs/{job_id}", dependencies=[Depends(require_token)])
    async def get_job(job_id: str, wait: float = Query(0, ge=0, le=MAX_WAIT_S)):
        job = job_or_404(job_id)
        if wait:
            await wait_for(job, wait)
        return manager.to_json(job)

    @app.get("/v1/jobs/{job_id}/musicxml", dependencies=[Depends(require_token)])
    def get_musicxml(job_id: str):
        job = job_or_404(job_id)
        if job.status != SUCCEEDED or job.musicxml is None:
            raise ApiError(409, "not_ready", f"job is {job.status}")
        return FileResponse(
            job.musicxml,
            media_type="application/vnd.recordare.musicxml+xml",
            filename="score.musicxml",
        )

    @app.delete("/v1/jobs/{job_id}", dependencies=[Depends(require_token)], status_code=204)
    def delete_job(job_id: str):
        if not manager.cancel(job_id):
            raise ApiError(404, "job_not_found", "no such job")
        return Response(status_code=204)

    return app


def _rmtree(path) -> None:
    import shutil

    shutil.rmtree(path, ignore_errors=True)


def app_factory() -> FastAPI:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    return create_app()
