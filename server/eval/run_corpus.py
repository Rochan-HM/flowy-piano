"""End-to-end test: send every corpus file to a running OMR server and score the MusicXML it returns.

    OMR_API_TOKEN=... python eval/run_corpus.py --url http://localhost:8000 --out /tmp/corpus-run

For each piece in testdata/manifest.json it uploads the PDF (all pages) and the two simulated phone
photos (page 1), then scores against the truth files (see score.py). A result PASSES when the two
hands come back as two staves in the right order, the measure count is within 10% of the truth and
the note pitch F1 is at least 0.90; PARTIAL when the hands are right and pitch F1 is at least 0.70.
Real phone photos (no verified truth) are compared with the server's own reading of the clean scan.
Exits 1 if any piece fails with --strict.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import score as S  # noqa: E402

TESTDATA = Path(__file__).resolve().parent.parent / "testdata"
PASS_PITCH, PARTIAL_PITCH, MEASURE_TOLERANCE = 0.90, 0.70, 0.10


def _request(method: str, url: str, token: str, body: bytes | None = None, ctype: str | None = None):
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if ctype:
        req.add_header("Content-Type", ctype)
    with urllib.request.urlopen(req, timeout=120) as resp:  # noqa: S310 - URL comes from the operator
        return resp.status, resp.read()


def recognize(base: str, token: str, path: Path, timeout_s: int = 900) -> tuple[dict, bytes | None, float]:
    boundary = uuid.uuid4().hex
    ctype = "application/pdf" if path.suffix == ".pdf" else "image/jpeg"
    body = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{path.name}"\r\n'
        f"Content-Type: {ctype}\r\n\r\n".encode()
        + path.read_bytes()
        + f"\r\n--{boundary}--\r\n".encode()
    )
    t0 = time.time()
    _, raw = _request("POST", f"{base}/v1/jobs?wait=30", token, body, f"multipart/form-data; boundary={boundary}")
    job = json.loads(raw)
    while job["status"] in ("queued", "running") and time.time() - t0 < timeout_s:
        _, raw = _request("GET", f"{base}/v1/jobs/{job['id']}?wait=30", token)
        job = json.loads(raw)
    elapsed = time.time() - t0
    if job["status"] != "succeeded":
        return job, None, elapsed
    _, xml = _request("GET", f"{base}{job['musicxml_url']}", token)
    return job, xml, elapsed


def truth_for(piece: dict, pages: list[int]) -> S.Staves:
    d = TESTDATA / "pieces" / piece["id"]
    items = []
    for tp in piece["truth_pages"]:
        if tp["page"] in pages:
            rng = tuple(tp["measures"]) if "measures" in tp else None
            items += [S.load(d / f, rng) for f in tp["truth"]]
    return S.concat(items)


def verdict(m: dict) -> str:
    if not m:
        return "FAIL"
    t = m["truth_measures"]
    measures_ok = abs(m["pred_measures"] - t) <= max(1, MEASURE_TOLERANCE * t)
    if m["hands_ok"] and measures_ok and m["pitch_f1"] >= PASS_PITCH:
        return "PASS"
    if m["hands_ok"] and m["pitch_f1"] >= PARTIAL_PITCH:
        return "PARTIAL"
    return "FAIL"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://localhost:8000")
    ap.add_argument("--token", default=os.environ.get("OMR_API_TOKEN", ""))
    ap.add_argument("--out", type=Path, default=Path("corpus-run"))
    ap.add_argument("--variants", default="pdf,photo-mild,photo-hard,real")
    ap.add_argument("--pieces", default="", help="comma-separated piece ids (default: all)")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()
    variants = args.variants.split(",")
    manifest = json.loads((TESTDATA / "manifest.json").read_text())
    args.out.mkdir(parents=True, exist_ok=True)
    rows = []

    for piece in manifest["pieces"]:
        if args.pieces and piece["id"] not in args.pieces.split(","):
            continue
        d = TESTDATA / "pieces" / piece["id"]
        for variant in variants:
            if variant == "real":
                continue
            src = d / ("score.pdf" if variant == "pdf" else f"{variant}.jpg")
            pages = list(range(1, piece["pdf_pages"] + 1)) if variant == "pdf" else [1]
            job, xml, elapsed = recognize(args.url, args.token, src)
            row = {"piece": piece["id"], "variant": variant, "status": job["status"], "seconds": round(elapsed, 1)}
            if xml:
                out = args.out / f"{piece['id']}--{variant}.musicxml"
                out.write_bytes(xml)
                metrics = S.score(truth_for(piece, pages), S.load(out))
                row.update(metrics)
                row["warnings"] = sorted({w["code"] for w in job["warnings"]})
            row["verdict"] = verdict(row if xml else {})
            rows.append(row)
            print(json.dumps(row), flush=True)

    if "real" in variants and not args.pieces:
        for rp in manifest["real_photos"]:
            d = TESTDATA / "real-photos" / rp["id"]
            readings = {}
            for f in rp["files"]:
                job, xml, elapsed = recognize(args.url, args.token, d / f)
                row = {"piece": rp["id"], "variant": f, "status": job["status"], "seconds": round(elapsed, 1)}
                if xml:
                    out = args.out / f"{rp['id']}--{Path(f).stem}.musicxml"
                    out.write_bytes(xml)
                    readings[f] = S.load(out)
                    row["staves"] = job["result"]["staff_count"]
                    row["measures"] = job["result"]["measure_count"]
                    if f != "scan.pdf" and "scan.pdf" in readings:
                        agree = S.score(readings["scan.pdf"], readings[f])
                        row["agreement_with_scan_pitch_f1"] = agree["pitch_f1"]
                rows.append(row)
                print(json.dumps(row), flush=True)

    (args.out / "results.json").write_text(json.dumps(rows, indent=1))
    print("\n| piece | input | verdict | hands | measures | pitch F1 | rhythm F1 | seconds |")
    print("|---|---|---|---|---|---|---|---|")
    for r in rows:
        if "verdict" in r:
            print(
                f"| {r['piece']} | {r['variant']} | {r['verdict']} | {r.get('hands_ok', '-')} | "
                f"{r.get('pred_measures', '-')}/{r.get('truth_measures', '-')} | {r.get('pitch_f1', '-')} | "
                f"{r.get('rhythm_f1', '-')} | {r['seconds']} |"
            )
        else:
            print(
                f"| {r['piece']} | {r['variant']} | {r['status']} | staves {r.get('staves', '-')} | "
                f"{r.get('measures', '-')} | agree {r.get('agreement_with_scan_pitch_f1', '-')} | - | {r['seconds']} |"
            )
    failed = [r for r in rows if r.get("verdict") == "FAIL"]
    return 1 if args.strict and failed else 0


if __name__ == "__main__":
    sys.exit(main())
