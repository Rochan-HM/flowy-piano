"""Simulate phone photos of printed sheet music.

Each PDF's first page is rasterized at 300 dpi and turned into two JPEGs:

- photo-mild.jpg: page fills ~88% of the frame, 1.5-3 degree rotation, slight perspective,
  soft light gradient, light blur and noise, JPEG q85.
- photo-hard.jpg: page fills ~72% of the frame, 4-6 degree rotation, strong perspective,
  page curl near the spine, a soft hand/phone shadow, warm uneven light, blur plus slight
  motion blur, noise, JPEG q72.

Seeds are fixed so the corpus is reproducible:

    python eval/make_photos.py testdata/pieces/*/score.pdf
"""

import argparse
import hashlib
from pathlib import Path

import cv2
import numpy as np
import pypdfium2 as pdfium

OUT_W, OUT_H = 2268, 3024


def rasterize_first_page(pdf: Path, dpi: int = 300) -> np.ndarray:
    doc = pdfium.PdfDocument(str(pdf))
    try:
        img = doc[0].render(scale=dpi / 72).to_pil().convert("RGB")
    finally:
        doc.close()
    return np.asarray(img)


def _curl(page: np.ndarray, amp: float) -> np.ndarray:
    h, w = page.shape[:2]
    mx, my = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
    bulge = amp * np.exp(-mx / (0.25 * w)) * np.sin(np.pi * my / h)
    wave = 0.35 * amp * np.sin(2 * np.pi * mx / w) * (my / h)
    return cv2.remap(page, mx, my + bulge + wave, cv2.INTER_LINEAR, borderValue=(255, 255, 255))


def simulate(page_rgb: np.ndarray, level: str, seed: int, corners_out: list | None = None) -> bytes:
    """corners_out, if given, receives the page corners in the photo (TL, TR, BR, BL)."""
    rng = np.random.default_rng(seed)
    hard = level == "hard"
    page = page_rgb.astype(np.float32) * np.array([0.93, 0.92, 0.88], np.float32) + 6
    if hard:
        page = _curl(page, amp=page.shape[0] * 0.0085)

    h, w = page.shape[:2]
    fill = 0.72 if hard else 0.88
    scale = fill * OUT_H / h
    pw, ph = w * scale, h * scale
    cx = OUT_W / 2 + rng.uniform(-40, 40)
    cy = OUT_H / 2 + rng.uniform(-40, 40)
    deg = rng.uniform(4, 6) if hard else rng.uniform(1.5, 3)
    ang = np.deg2rad(deg * rng.choice([-1, 1]))
    rot = np.array([[np.cos(ang), -np.sin(ang)], [np.sin(ang), np.cos(ang)]])
    corners = np.array([[-pw / 2, -ph / 2], [pw / 2, -ph / 2], [pw / 2, ph / 2], [-pw / 2, ph / 2]])
    corners = corners @ rot.T + [cx, cy]
    k = rng.uniform(0.06, 0.09) if hard else rng.uniform(0.015, 0.03)
    corners[0, 0] += k * pw
    corners[1, 0] -= k * pw
    corners += rng.normal(0, 18 if hard else 6, corners.shape)
    if corners_out is not None:
        corners_out.extend(corners.tolist())
    src = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    M = cv2.getPerspectiveTransform(src, np.float32(corners))

    bg_color = np.array([96, 82, 70], np.float32) if hard else np.array([140, 138, 132], np.float32)
    bg = np.ones((OUT_H, OUT_W, 3), np.float32) * bg_color
    bg += rng.normal(0, 6, (OUT_H, OUT_W, 1)).astype(np.float32)
    warped = cv2.warpPerspective(page, M, (OUT_W, OUT_H), flags=cv2.INTER_AREA)
    mask = cv2.warpPerspective(np.ones((h, w), np.float32), M, (OUT_W, OUT_H))
    mask = cv2.GaussianBlur(mask, (5, 5), 0)[..., None]
    img = warped * mask + bg * (1 - mask)

    yy, xx = np.mgrid[0:OUT_H, 0:OUT_W].astype(np.float32)
    gdir = rng.uniform(0, 2 * np.pi)
    grad = np.cos(gdir) * (xx / OUT_W - 0.5) + np.sin(gdir) * (yy / OUT_H - 0.5)
    light = 1.0 - (0.35 if hard else 0.15) * (grad + 0.5)
    r2 = ((xx - OUT_W / 2) / OUT_W) ** 2 + ((yy - OUT_H / 2) / OUT_H) ** 2
    light *= 1.0 - (0.45 if hard else 0.2) * r2
    if hard:
        shadow = np.zeros((OUT_H, OUT_W), np.float32)
        x0 = rng.uniform(0.55, 0.75) * OUT_W
        pts = np.int32([[x0, 0], [OUT_W, 0], [OUT_W, OUT_H * 0.55], [x0 + 0.1 * OUT_W, OUT_H * 0.45]])
        cv2.fillPoly(shadow, [pts], 1.0)
        shadow = cv2.GaussianBlur(shadow, (0, 0), 0.03 * OUT_W)
        light *= 1.0 - 0.45 * shadow
    tint = np.array([1.0, 0.97, 0.9] if hard else [1.0, 0.99, 0.97], np.float32)
    img = img * light[..., None] * tint

    img = cv2.GaussianBlur(img, (0, 0), 1.1 if hard else 0.7)
    if hard:
        kern = np.zeros((5, 5), np.float32)
        kern[2, :] = 1
        kern = cv2.warpAffine(kern, cv2.getRotationMatrix2D((2, 2), rng.uniform(0, 180), 1), (5, 5))
        img = cv2.filter2D(img, -1, kern / kern.sum())
    img += rng.normal(0, 7 if hard else 3, img.shape).astype(np.float32)
    img = np.clip(img, 0, 255).astype(np.uint8)
    ok, enc = cv2.imencode(
        ".jpg", cv2.cvtColor(img, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, 72 if hard else 85]
    )
    assert ok
    return enc.tobytes()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pdfs", nargs="+", type=Path)
    args = parser.parse_args()
    for pdf in args.pdfs:
        page = rasterize_first_page(pdf)
        seed = int(hashlib.sha256(pdf.parent.name.encode()).hexdigest()[:8], 16)
        for level in ("mild", "hard"):
            out = pdf.parent / f"photo-{level}.jpg"
            out.write_bytes(simulate(page, level, seed + (level == "hard")))
            print(out)


if __name__ == "__main__":
    main()
