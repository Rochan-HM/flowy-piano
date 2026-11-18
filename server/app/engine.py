"""OMR engines. Each engine turns one page image into one MusicXML file."""

from __future__ import annotations

import functools
import os
import shutil
import subprocess
from importlib import metadata
from pathlib import Path


class EngineError(Exception):
    pass


class HomrEngine:
    """homr (https://github.com/liebharc/homr, AGPL-3.0), run as a separate process per page.

    A process per page keeps memory bounded (onnxruntime arenas are released on exit), lets a
    timeout kill a stuck page, and keeps homr's AGPL code in its own process.
    """

    name = "homr"
    supports_fingering = False

    def __init__(self) -> None:
        self.binary = os.environ.get("OMR_HOMR_BIN") or shutil.which("homr") or "homr"

    @functools.cached_property
    def version(self) -> str:
        commit = os.environ.get("HOMR_COMMIT", "")
        try:
            v = metadata.version("homr")
        except metadata.PackageNotFoundError:
            # homr usually lives in its own venv next to its launcher
            python = Path(shutil.which(self.binary) or self.binary).parent / "python"
            try:
                v = subprocess.run(
                    [str(python), "-c", "import importlib.metadata as m; print(m.version('homr'))"],
                    capture_output=True, text=True, timeout=30, check=True,
                ).stdout.strip()
            except (OSError, subprocess.SubprocessError):
                v = "unknown"
        return f"{v} ({commit[:12]})" if commit and commit[:7] not in v else v

    def ready(self) -> bool:
        return shutil.which(self.binary) is not None or Path(self.binary).exists()

    def recognize_page(self, image: Path, timeout_s: int) -> Path:
        out = image.with_suffix(".musicxml")
        try:
            proc = subprocess.run(
                [self.binary, "--no-title", str(image)],
                cwd=image.parent,
                capture_output=True,
                text=True,
                timeout=timeout_s,
            )
        except subprocess.TimeoutExpired as e:
            raise EngineError(f"timed out after {timeout_s} s") from e
        if proc.returncode != 0 or not out.exists():
            tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-3:]
            raise EngineError(f"homr exited with {proc.returncode}: {' | '.join(tail)}")
        return out


class FakeEngine:
    """Returns a fixed MusicXML file for every page. Used by the tests."""

    name = "fake"
    supports_fingering = False
    version = "0"

    def __init__(self, fixture: Path, delay_s: float = 0.0, fail_pages: set[int] | None = None) -> None:
        self.fixture = fixture
        self.delay_s = delay_s
        self.fail_pages = fail_pages or set()

    def ready(self) -> bool:
        return True

    def recognize_page(self, image: Path, timeout_s: int) -> Path:
        import time

        time.sleep(self.delay_s)
        page_no = int(image.stem.split("-")[-1])
        if page_no in self.fail_pages:
            raise EngineError("fake failure")
        out = image.with_suffix(".musicxml")
        shutil.copy(self.fixture, out)
        return out


def create_engine(name: str):
    if name == "homr":
        return HomrEngine()
    raise ValueError(f"unknown OMR_ENGINE {name!r}")
