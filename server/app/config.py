import os
from dataclasses import dataclass
from pathlib import Path


def _int(name: str, default: int) -> int:
    value = os.environ.get(name)
    return int(value) if value not in (None, "") else default


@dataclass(frozen=True)
class Settings:
    api_token: str
    max_upload_mb: int
    max_pdf_pages: int
    max_image_megapixels: int
    pdf_dpi: int
    workers: int
    max_queued_jobs: int
    page_timeout_s: int
    job_ttl_s: int
    work_dir: Path
    engine: str

    @property
    def max_upload_bytes(self) -> int:
        return self.max_upload_mb * 1024 * 1024


def load_settings() -> Settings:
    return Settings(
        api_token=os.environ.get("OMR_API_TOKEN", ""),
        max_upload_mb=_int("OMR_MAX_UPLOAD_MB", 20),
        max_pdf_pages=_int("OMR_MAX_PDF_PAGES", 12),
        max_image_megapixels=_int("OMR_MAX_IMAGE_MEGAPIXELS", 60),
        pdf_dpi=_int("OMR_PDF_DPI", 300),
        workers=_int("OMR_WORKERS", 1),
        max_queued_jobs=_int("OMR_MAX_QUEUED_JOBS", 20),
        page_timeout_s=_int("OMR_PAGE_TIMEOUT_S", 300),
        job_ttl_s=_int("OMR_JOB_TTL_S", 3600),
        work_dir=Path(os.environ.get("OMR_WORK_DIR", "/tmp/omr-jobs")),
        engine=os.environ.get("OMR_ENGINE", "homr"),
    )
