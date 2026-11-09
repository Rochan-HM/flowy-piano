# OMR server

Turns photos and PDFs of printed piano music into MusicXML for the iOS app. Upload one PDF or
several page images, poll the job, then download one merged MusicXML file and a JSON summary
(parts, staves, measures, warnings).

Recognition uses [homr](https://github.com/liebharc/homr) (AGPL-3.0, CPU, ONNX models) pinned to
commit `33dd138` in the `Dockerfile`. homr was the most accurate option on our corpus of
public-domain piano scores and simulated phone photos and does well on real phone photos; see the
project report `docs/sheet-music-recognition.md` for the comparison with copisteria, Audiveris and oemer.

## Run

```sh
docker build -t rochan-piano-omr server/
docker run -p 8000:8000 -e OMR_API_TOKEN=change-me rochan-piano-omr
curl localhost:8000/healthz
curl -H "Authorization: Bearer change-me" -F file=@server/testdata/pieces/mutopia-burgmuller-arabesque/photo-hard.jpg \
  "localhost:8000/v1/jobs?wait=30"
```

The build downloads homr's model weights (about 160 MB) from homr's GitHub releases; nothing large
is committed. The image is about 1.2 GB on disk (about 370 MB compressed).

## API

All `/v1` endpoints need `Authorization: Bearer $OMR_API_TOKEN`. Errors are
`{"error": {"code": "...", "message": "..."}}`.

| Method and path | What it does |
|---|---|
| `GET /healthz` | No auth. `{"status": "ok", "engine": {...}, "jobs": {...}, "limits": {...}}` |
| `POST /v1/jobs` | Multipart form, field `file`: one PDF and/or images (JPEG, PNG, HEIC, TIFF, WebP); repeat `file` for several pages, in page order. Optional `?wait=0..30` seconds. Returns the job: `202` while queued or running, `200` if it finished within `wait`. `Location` header points at the job. |
| `GET /v1/jobs/{id}` | The job. Optional `?wait=0..30` long-polls until it finishes. |
| `GET /v1/jobs/{id}/musicxml` | The merged MusicXML (`application/vnd.recordare.musicxml+xml`). `409` until the job has succeeded. |
| `DELETE /v1/jobs/{id}` | Cancels or forgets the job and deletes its files. `204`. |

A page takes 10-25 s on 4 CPU cores, so clients should post with `wait=30`, then repeat
`GET /v1/jobs/{id}?wait=30` until `status` is `succeeded` or `failed`.

Job object:

```json
{
  "id": "d72477bf24de4c1d844780df40368e70",
  "status": "succeeded",
  "created_at": "2026-11-09T10:21:02+00:00",
  "started_at": "2026-11-09T10:21:02+00:00",
  "finished_at": "2026-11-09T10:21:19+00:00",
  "queue_position": null,
  "progress": {"pages_done": 1, "pages_total": 1},
  "inputs": [{"filename": "photo-hard.jpg", "bytes": 666314}],
  "pages": [
    {"page": 1, "source": "photo-hard.jpg", "status": "ok", "staves": 2, "measures": 34, "notes": 284,
     "seconds": 17.3, "warnings": []}
  ],
  "result": {
    "title": null,
    "parts": [{"id": "P1", "name": "Piano", "staves": 2, "measures": 34, "notes": 284,
               "notes_per_staff": [108, 176], "fingerings": 0}],
    "part_count": 1, "staff_count": 2, "measure_count": 34, "note_count": 284,
    "key": {"fifths": 0, "mode": null}, "time": "2/4",
    "has_fingering": false,
    "rhythm_suspect_measures": [16]
  },
  "warnings": [
    {"code": "rhythm_suspect_measures", "measures": [16],
     "message": "1 of 34 measures in the first part do not add up to the time signature; check rhythms there"},
    {"code": "fingering_not_recognized", "message": "finger numbers printed in the score are not read by this engine"}
  ],
  "error": null,
  "musicxml_url": "/v1/jobs/d72477bf24de4c1d844780df40368e70/musicxml",
  "engine": {"name": "homr", "version": "0.7.0+33dd138b0a79"}
}
```

`status` is `queued`, `running`, `succeeded`, `failed` or `canceled`. A page that fails or has no
music is skipped with a warning and the remaining pages are still merged; the job fails only when no
page yields music (`error.code = "recognition_failed"`). In the MusicXML a piano is one part with
two staves: staff 1 is the right hand, staff 2 the left hand.

Warning codes: `low_resolution`, `page_failed`, `no_music_found`, `part_count_mismatch`,
`no_grand_staff`, `empty_staff`, `rhythm_suspect_measures`, `fingering_not_recognized`.
Error codes: `unauthorized` (401), `job_not_found` (404), `not_ready` (409), `upload_too_large`,
`too_many_pages`, `image_too_large` (413), `unsupported_type` (415), `invalid_pdf`,
`invalid_image`, `no_input` (422), `queue_full` (429, with `Retry-After`).

## Configuration

| Variable | Default | |
|---|---|---|
| `OMR_API_TOKEN` | (required) | Bearer token. The server refuses to start without it unless `OMR_ALLOW_NO_AUTH=1`. |
| `OMR_MAX_UPLOAD_MB` | 20 | Total size of one request. |
| `OMR_MAX_PDF_PAGES` | 12 | Pages per job (PDF pages plus images). |
| `OMR_MAX_IMAGE_MEGAPIXELS` | 60 | Larger images are rejected; PDF pages are rendered below it. |
| `OMR_PDF_DPI` | 300 | PDF render resolution. |
| `OMR_WORKERS` | 1 | Pages recognized in parallel. Each needs about 1.3 GB RAM and uses all cores. |
| `OMR_MAX_QUEUED_JOBS` | 20 | More waiting jobs get `429`. |
| `OMR_PAGE_TIMEOUT_S` | 300 | A page taking longer is skipped with a warning. |
| `OMR_JOB_TTL_S` | 3600 | Finished jobs and their files are deleted after this. |
| `OMR_WORK_DIR` | `/tmp/omr-jobs` | Uploaded pages and results. |

Jobs live in memory in a single process, so run one container per replica and route a job's
follow-up requests to the replica that created it (or use a single replica).

## Deployment

- CPU only; no GPU needed. 2 vCPU / 2 GB RAM works for one user at a time (about 25-35 s per page);
  4 vCPU / 4 GB gives 10-20 s per page. Add 1.3 GB per extra `OMR_WORKERS`.
- Disk: the image (1.2 GB) plus a few MB per job under `OMR_WORK_DIR`.
- Put it behind HTTPS (the token is a shared secret) and set a request body limit at the proxy too.
- homr is AGPL-3.0. It runs unmodified in its own virtualenv and process; if you change homr and
  offer the service to others, publish your homr changes.

## Development

```sh
python -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest            # API tests with a fake engine, no models needed
```

For a local run without Docker, install homr (`pip install "homr[cpu] @ git+https://github.com/liebharc/homr@33dd138b0a79a6e513bf2b2e31caddde12c01063"`
in another venv), then `OMR_HOMR_BIN=/path/to/venv/bin/homr OMR_API_TOKEN=dev uvicorn app.main:app_factory --factory`.

## Test corpus and end-to-end check

`testdata/` holds public-domain piano scores (Mutopia engravings, Internet Archive scans of 1893
and 1903 Schirmer editions, a fingered MuseScore render, and real phone photos), each with
simulated phone photos and truth files; see `testdata/README.md` for sources and licenses.
`eval/run_corpus.py` sends all of it to a running server and scores the MusicXML:

```sh
pip install -r eval/requirements.txt
OMR_API_TOKEN=change-me python eval/run_corpus.py --url http://localhost:8000 --out /tmp/corpus-run
```

`eval/score.py` compares any MusicXML with a truth file; `eval/make_photos.py` regenerates the
simulated photos.
