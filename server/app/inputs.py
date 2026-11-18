"""Turn uploaded files (images or PDFs) into one PNG per page."""

from __future__ import annotations

import io
from dataclasses import dataclass, field
from pathlib import Path

import pypdfium2 as pdfium
from PIL import Image, ImageOps

try:
    from pillow_heif import register_heif_opener

    register_heif_opener()
    HEIF_SUPPORTED = True
except ImportError:  # pragma: no cover - optional dependency
    HEIF_SUPPORTED = False

MIN_SHORT_SIDE_PX = 1000


class InputError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


@dataclass
class Page:
    path: Path
    source: str
    warnings: list[dict] = field(default_factory=list)


def sniff(data: bytes) -> str | None:
    if data.startswith(b"%PDF-"):
        return "pdf"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data[:4] in (b"II*\x00", b"MM\x00*"):
        return "tiff"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    if data[4:8] == b"ftyp" and data[8:12] in (b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1"):
        return "heic"
    return None


def _low_res_warning(img: Image.Image, label: str) -> list[dict]:
    if min(img.size) < MIN_SHORT_SIDE_PX:
        return [
            {
                "code": "low_resolution",
                "message": f"{label} is only {img.size[0]}x{img.size[1]} px; "
                f"use at least {MIN_SHORT_SIDE_PX} px on the short side for reliable results",
            }
        ]
    return []


def _pdf_pages(data: bytes, filename: str, out_dir: Path, start: int, dpi: int, max_pages: int, max_px: int) -> list[Page]:
    try:
        doc = pdfium.PdfDocument(data)
    except pdfium.PdfiumError as e:
        raise InputError(422, "invalid_pdf", f"{filename}: cannot open PDF ({e})") from e
    try:
        n = len(doc)
        if n == 0:
            raise InputError(422, "invalid_pdf", f"{filename}: PDF has no pages")
        if start + n > max_pages:
            raise InputError(
                413, "too_many_pages", f"{filename}: {n} pages; at most {max_pages} pages per job"
            )
        pages = []
        for i in range(n):
            page = doc[i]
            w, h = page.get_size()
            scale = dpi / 72
            if w * h * scale * scale > max_px:
                scale = (max_px / (w * h)) ** 0.5
            img = page.render(scale=scale).to_pil().convert("RGB")
            path = out_dir / f"page-{start + len(pages) + 1:03d}.png"
            img.save(path)
            pages.append(Page(path, f"{filename} page {i + 1}", _low_res_warning(img, f"{filename} page {i + 1}")))
        return pages
    finally:
        doc.close()


def _image_page(data: bytes, kind: str, filename: str, out_dir: Path, index: int, max_px: int) -> Page:
    if kind == "heic" and not HEIF_SUPPORTED:
        raise InputError(415, "unsupported_type", f"{filename}: HEIC is not supported by this server; send JPEG")
    Image.MAX_IMAGE_PIXELS = max_px
    try:
        with Image.open(io.BytesIO(data)) as im:
            im = ImageOps.exif_transpose(im)
            img = im.convert("RGB")
    except Image.DecompressionBombError as e:
        raise InputError(413, "image_too_large", f"{filename}: image exceeds {max_px // 1_000_000} megapixels") from e
    except Exception as e:  # noqa: BLE001 - Pillow raises many types for corrupt files
        raise InputError(422, "invalid_image", f"{filename}: cannot decode image ({e})") from e
    path = out_dir / f"page-{index + 1:03d}.png"
    img.save(path)
    return Page(path, filename, _low_res_warning(img, filename))


def prepare_pages(
    files: list[tuple[str, bytes]], out_dir: Path, *, dpi: int, max_pages: int, max_megapixels: int
) -> list[Page]:
    """files: (filename, content) in page order. Returns one PNG per page."""
    out_dir.mkdir(parents=True, exist_ok=True)
    max_px = max_megapixels * 1_000_000
    pages: list[Page] = []
    for filename, data in files:
        kind = sniff(data)
        if kind is None:
            raise InputError(415, "unsupported_type", f"{filename}: expected a PDF, JPEG, PNG, HEIC, TIFF or WebP file")
        if kind == "pdf":
            pages += _pdf_pages(data, filename, out_dir, len(pages), dpi, max_pages, max_px)
        else:
            if len(pages) + 1 > max_pages:
                raise InputError(413, "too_many_pages", f"at most {max_pages} pages per job")
            pages.append(_image_page(data, kind, filename, out_dir, len(pages), max_px))
    if not pages:
        raise InputError(422, "no_input", "no file uploaded")
    return pages
