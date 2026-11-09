"""Merge per-page MusicXML files and summarize a score for the API response."""

from __future__ import annotations

import copy
import xml.etree.ElementTree as ET
from fractions import Fraction
from pathlib import Path


def _parse(path: Path) -> ET.Element:
    return ET.parse(path).getroot()  # noqa: S314 - files are written by our own engine


def _staves(part: ET.Element) -> int:
    n = 1
    for st in part.iter("staves"):
        try:
            n = max(n, int(st.text or 1))
        except ValueError:
            pass
    return n


def _attr_state(part: ET.Element) -> dict:
    """The last divisions, key, time and clef (per staff) of a part, as XML strings."""
    state: dict = {}
    for measure in part.findall("measure"):
        for attrs in measure.findall("attributes"):
            for child in attrs:
                if child.tag == "clef":
                    state[("clef", child.get("number", "1"))] = ET.tostring(child)
                elif child.tag in ("divisions", "key", "time"):
                    state[child.tag] = ET.tostring(child)
    return state


def _rest_measure(number: int, divisions: int, beats: int, beat_type: int, staves: int) -> ET.Element:
    m = ET.Element("measure", number=str(number))
    dur = str(int(divisions * 4 * beats / beat_type))
    for staff in range(1, staves + 1):
        if staff > 1:
            backup = ET.SubElement(m, "backup")
            ET.SubElement(backup, "duration").text = dur
        note = ET.SubElement(m, "note")
        ET.SubElement(note, "rest", measure="yes")
        ET.SubElement(note, "duration").text = dur
        ET.SubElement(note, "voice").text = str(staff)
        ET.SubElement(note, "staff").text = str(staff)
    return m


def _time_of(part: ET.Element) -> tuple[int, int, int]:
    divisions, beats, beat_type = 1, 4, 4
    for d in part.iter("divisions"):
        divisions = int(d.text or 1)
    for t in part.iter("time"):
        try:
            beats = int((t.findtext("beats") or "4").split("+")[0])
            beat_type = int(t.findtext("beat-type") or 4)
        except ValueError:
            pass
    return divisions, beats, beat_type


def merge_pages(pages: list[Path], out: Path) -> list[dict]:
    """Concatenate page scores part by part. Returns warnings."""
    warnings: list[dict] = []
    base = _parse(pages[0])
    base_parts = base.findall("part")
    for page_no, path in enumerate(pages[1:], start=2):
        doc = _parse(path)
        parts = doc.findall("part")
        if len(parts) != len(base_parts):
            warnings.append(
                {
                    "code": "part_count_mismatch",
                    "page": page_no,
                    "message": f"page {page_no} has {len(parts)} part(s), page 1 has {len(base_parts)}; "
                    "missing parts are padded with rests and extra parts are dropped",
                }
            )
        for i, base_part in enumerate(base_parts):
            existing = base_part.findall("measure")
            offset = len(existing)
            if i >= len(parts):
                divisions, beats, beat_type = _time_of(base_part)
                n_new = max((len(p.findall("measure")) for p in parts), default=0)
                for k in range(n_new):
                    base_part.append(_rest_measure(offset + k + 1, divisions, beats, beat_type, _staves(base_part)))
                continue
            state = _attr_state(base_part)
            for k, measure in enumerate(parts[i].findall("measure")):
                measure = copy.deepcopy(measure)
                measure.set("number", str(offset + k + 1))
                if k == 0:
                    for attrs in measure.findall("attributes"):
                        for child in list(attrs):
                            key = ("clef", child.get("number", "1")) if child.tag == "clef" else child.tag
                            if key in state and state[key] == ET.tostring(child):
                                attrs.remove(child)
                        if len(attrs) == 0:
                            measure.remove(attrs)
                base_part.append(measure)
    ET.ElementTree(base).write(out, encoding="utf-8", xml_declaration=True)
    return warnings


def _measure_length(divisions: int, beats: int, beat_type: int) -> Fraction:
    return Fraction(divisions * 4 * beats, beat_type)


def summarize(path: Path) -> dict:
    root = _parse(path)
    names = {sp.get("id"): (sp.findtext("part-name") or "").strip() for sp in root.iter("score-part")}
    title = (root.findtext("work/work-title") or root.findtext("movement-title") or "").strip()
    parts = []
    first_key = first_time = None
    suspect: list[int] = []
    for part in root.findall("part"):
        staves = _staves(part)
        measures = part.findall("measure")
        notes_per_staff = [0] * staves
        fingerings = 0
        divisions, beats, beat_type = 1, 4, 4
        for idx, measure in enumerate(measures):
            for attrs in measure.findall("attributes"):
                if attrs.findtext("divisions"):
                    divisions = int(attrs.findtext("divisions"))
                t = attrs.find("time")
                if t is not None:
                    try:
                        beats = int((t.findtext("beats") or "4").split("+")[0])
                        beat_type = int(t.findtext("beat-type") or 4)
                    except ValueError:
                        pass
                    if first_time is None:
                        first_time = f"{t.findtext('beats')}/{t.findtext('beat-type')}"
                k = attrs.find("key")
                if k is not None and first_key is None:
                    first_key = {"fifths": int(k.findtext("fifths") or 0), "mode": k.findtext("mode") or None}
            voice_totals: dict[tuple[str, str], Fraction] = {}
            for note in measure.findall("note"):
                staff = int(note.findtext("staff") or 1)
                if note.find("rest") is None and 1 <= staff <= staves:
                    notes_per_staff[staff - 1] += 1
                fingerings += len(note.findall("notations/technical/fingering"))
                if note.find("chord") is not None or note.find("grace") is not None:
                    continue
                key = (note.findtext("staff") or "1", note.findtext("voice") or "1")
                voice_totals[key] = voice_totals.get(key, Fraction(0)) + Fraction(note.findtext("duration") or 0)
            expected = _measure_length(divisions, beats, beat_type)
            staff_max: dict[str, Fraction] = {}
            for (staff, _voice), total in voice_totals.items():
                staff_max[staff] = max(staff_max.get(staff, Fraction(0)), total)
            is_edge = idx in (0, len(measures) - 1) or measure.get("implicit") == "yes"
            if staff_max and any(v != expected for v in staff_max.values()) and not (
                is_edge and all(v <= expected for v in staff_max.values())
            ):
                if not parts:
                    suspect.append(int(measure.get("number", idx + 1)))
        parts.append(
            {
                "id": part.get("id"),
                "name": names.get(part.get("id"), ""),
                "staves": staves,
                "measures": len(measures),
                "notes": sum(notes_per_staff),
                "notes_per_staff": notes_per_staff,
                "fingerings": fingerings,
            }
        )
    return {
        "title": title or None,
        "parts": parts,
        "part_count": len(parts),
        "staff_count": sum(p["staves"] for p in parts),
        "measure_count": max((p["measures"] for p in parts), default=0),
        "note_count": sum(p["notes"] for p in parts),
        "key": first_key,
        "time": first_time,
        "has_fingering": any(p["fingerings"] for p in parts),
        "rhythm_suspect_measures": suspect,
    }


def score_warnings(summary: dict, *, engine_reads_fingering: bool) -> list[dict]:
    w: list[dict] = []
    if summary["part_count"] == 0 or summary["measure_count"] == 0:
        w.append({"code": "empty_score", "message": "no music was recognized"})
        return w
    piano_like = [p for p in summary["parts"] if p["staves"] == 2]
    if not piano_like:
        w.append(
            {
                "code": "no_grand_staff",
                "message": "no two-staff (grand staff) part found; right and left hand may be merged or split "
                "across parts",
            }
        )
    for p in summary["parts"]:
        empty = [i + 1 for i, n in enumerate(p["notes_per_staff"]) if n == 0]
        if empty and p["notes"]:
            w.append(
                {"code": "empty_staff", "message": f"part {p['id']}: staff {', '.join(map(str, empty))} has no notes"}
            )
    suspect = summary["rhythm_suspect_measures"]
    if suspect:
        w.append(
            {
                "code": "rhythm_suspect_measures",
                "message": f"{len(suspect)} of {summary['parts'][0]['measures']} measures in the first part do not add "
                "up to the time signature; check rhythms there",
                "measures": suspect,
            }
        )
    if not engine_reads_fingering:
        w.append(
            {
                "code": "fingering_not_recognized",
                "message": "finger numbers printed in the score are not read by this engine",
            }
        )
    return w
