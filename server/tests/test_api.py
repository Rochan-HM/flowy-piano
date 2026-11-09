import dataclasses
import io
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.config import load_settings
from app.engine import FakeEngine
from app.main import create_app

FIXTURE = Path(__file__).parent / "fixtures" / "homr-minuet-page.musicxml"
TOKEN = "test-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


def png_bytes(size=(1240, 1754)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, "white").save(buf, "PNG")
    return buf.getvalue()


def pdf_bytes(pages: int) -> bytes:
    buf = io.BytesIO()
    imgs = [Image.new("RGB", (612, 792), "white") for _ in range(pages)]
    imgs[0].save(buf, "PDF", save_all=True, append_images=imgs[1:], resolution=72)
    return buf.getvalue()


@pytest.fixture
def make_client(tmp_path):
    clients = []

    def _make(engine=None, **overrides):
        settings = dataclasses.replace(load_settings(), api_token=TOKEN, work_dir=tmp_path / "jobs", **overrides)
        app = create_app(settings, engine or FakeEngine(FIXTURE))
        client = TestClient(app)
        client.__enter__()
        clients.append(client)
        return client

    yield _make
    for c in clients:
        c.__exit__(None, None, None)


def test_health_is_public(make_client):
    r = make_client().get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["limits"]["max_pages"] == 12


def test_auth_required(make_client):
    c = make_client()
    files = {"file": ("p.png", png_bytes(), "image/png")}
    assert c.post("/v1/jobs", files=files).status_code == 401
    r = c.post("/v1/jobs", files=files, headers={"Authorization": "Bearer nope"})
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "unauthorized"


def test_image_roundtrip(make_client):
    c = make_client()
    r = c.post("/v1/jobs?wait=10", files={"file": ("p.png", png_bytes(), "image/png")}, headers=AUTH)
    assert r.status_code == 200, r.text
    job = r.json()
    assert job["status"] == "succeeded"
    assert job["result"]["parts"][0]["staves"] == 2
    assert job["result"]["measure_count"] == 33
    assert job["result"]["key"] == {"fifths": 1, "mode": None}
    assert job["result"]["time"] == "3/4"
    codes = {w["code"] for w in job["warnings"]}
    assert "fingering_not_recognized" in codes
    xml = c.get(job["musicxml_url"], headers=AUTH)
    assert xml.status_code == 200
    assert xml.headers["content-type"].startswith("application/vnd.recordare.musicxml+xml")
    assert b"<score-partwise" in xml.content


def test_multipage_pdf_is_merged(make_client):
    c = make_client()
    r = c.post("/v1/jobs?wait=10", files={"file": ("s.pdf", pdf_bytes(3), "application/pdf")}, headers=AUTH)
    job = r.json()
    assert job["status"] == "succeeded", job
    assert job["progress"] == {"pages_done": 3, "pages_total": 3}
    assert job["result"]["measure_count"] == 99
    assert [p["measures"] for p in job["pages"]] == [33, 33, 33]
    xml = c.get(job["musicxml_url"], headers=AUTH).text
    # the clef/key/time restated at the top of pages 2 and 3 are dropped
    assert xml.count("<time>") == 1


def test_multiple_images_in_order(make_client):
    c = make_client()
    files = [("file", ("1.png", png_bytes(), "image/png")), ("file", ("2.jpg", _jpeg(), "image/jpeg"))]
    job = c.post("/v1/jobs?wait=10", files=files, headers=AUTH).json()
    assert job["status"] == "succeeded"
    assert [p["source"] for p in job["pages"]] == ["1.png", "2.jpg"]


def _jpeg() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (1500, 2000), "white").save(buf, "JPEG")
    return buf.getvalue()


def test_failed_page_is_reported_and_skipped(make_client):
    c = make_client(engine=FakeEngine(FIXTURE, fail_pages={2}))
    job = c.post("/v1/jobs?wait=10", files={"file": ("s.pdf", pdf_bytes(3), "application/pdf")}, headers=AUTH).json()
    assert job["status"] == "succeeded"
    assert job["result"]["measure_count"] == 66
    assert [p["status"] for p in job["pages"]] == ["ok", "failed", "ok"]
    assert any(w["code"] == "page_failed" and w["page"] == 2 for w in job["warnings"])


def test_all_pages_failing_fails_job(make_client):
    c = make_client(engine=FakeEngine(FIXTURE, fail_pages={1}))
    job = c.post("/v1/jobs?wait=10", files={"file": ("p.png", png_bytes(), "image/png")}, headers=AUTH).json()
    assert job["status"] == "failed"
    assert job["error"]["code"] == "recognition_failed"
    assert c.get(f"/v1/jobs/{job['id']}/musicxml", headers=AUTH).status_code == 409


def test_async_polling(make_client):
    c = make_client(engine=FakeEngine(FIXTURE, delay_s=0.6))
    r = c.post("/v1/jobs", files={"file": ("p.png", png_bytes(), "image/png")}, headers=AUTH)
    assert r.status_code == 202
    assert r.headers["location"] == f"/v1/jobs/{r.json()['id']}"
    assert r.json()["status"] in ("queued", "running")
    deadline = time.time() + 10
    while time.time() < deadline:
        job = c.get(r.headers["location"], headers=AUTH).json()
        if job["status"] == "succeeded":
            break
        time.sleep(0.1)
    assert job["status"] == "succeeded"


def test_long_poll_on_get(make_client):
    c = make_client(engine=FakeEngine(FIXTURE, delay_s=0.5))
    job = c.post("/v1/jobs", files={"file": ("p.png", png_bytes(), "image/png")}, headers=AUTH).json()
    job = c.get(f"/v1/jobs/{job['id']}?wait=10", headers=AUTH).json()
    assert job["status"] == "succeeded"


def test_unsupported_type(make_client):
    r = make_client().post("/v1/jobs", files={"file": ("a.txt", b"hello", "text/plain")}, headers=AUTH)
    assert r.status_code == 415
    assert r.json()["error"]["code"] == "unsupported_type"


def test_upload_size_limit(make_client):
    c = make_client(max_upload_mb=1)
    big = b"\x89PNG\r\n\x1a\n" + b"0" * (2 * 1024 * 1024)
    r = c.post("/v1/jobs", files={"file": ("big.png", big, "image/png")}, headers=AUTH)
    assert r.status_code == 413
    assert r.json()["error"]["code"] == "upload_too_large"


def test_page_limit(make_client):
    c = make_client(max_pdf_pages=2)
    r = c.post("/v1/jobs", files={"file": ("s.pdf", pdf_bytes(3), "application/pdf")}, headers=AUTH)
    assert r.status_code == 413
    assert r.json()["error"]["code"] == "too_many_pages"


def test_corrupt_image(make_client):
    r = make_client().post(
        "/v1/jobs", files={"file": ("x.jpg", b"\xff\xd8\xff" + b"junk" * 100, "image/jpeg")}, headers=AUTH
    )
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "invalid_image"


def test_low_resolution_warning(make_client):
    c = make_client()
    job = c.post("/v1/jobs?wait=10", files={"file": ("s.png", png_bytes((600, 800)), "image/png")}, headers=AUTH).json()
    assert any(w["code"] == "low_resolution" for w in job["warnings"])


def test_queue_full(make_client):
    c = make_client(engine=FakeEngine(FIXTURE, delay_s=2), max_queued_jobs=1)
    files = {"file": ("p.png", png_bytes(), "image/png")}
    codes = [c.post("/v1/jobs", files=files, headers=AUTH).status_code for _ in range(4)]
    assert 429 in codes


def test_delete(make_client):
    c = make_client()
    job = c.post("/v1/jobs?wait=10", files={"file": ("p.png", png_bytes(), "image/png")}, headers=AUTH).json()
    assert c.delete(f"/v1/jobs/{job['id']}", headers=AUTH).status_code == 204
    assert c.get(f"/v1/jobs/{job['id']}", headers=AUTH).status_code == 404


def test_refuses_to_start_without_token(monkeypatch, tmp_path):
    monkeypatch.delenv("OMR_ALLOW_NO_AUTH", raising=False)
    settings = dataclasses.replace(load_settings(), api_token="", work_dir=tmp_path)
    with pytest.raises(RuntimeError):
        create_app(settings, FakeEngine(FIXTURE))
