import xml.etree.ElementTree as ET
from pathlib import Path

from app.musicxml import merge_pages, score_warnings, summarize

FIXTURE = Path(__file__).parent / "fixtures" / "homr-minuet-page.musicxml"

ONE_STAFF = """<?xml version="1.0"?>
<score-partwise version="4.0"><part-list><score-part id="P1"><part-name>Voice</part-name></score-part></part-list>
<part id="P1"><measure number="1"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time>
<clef><sign>G</sign><line>2</line></clef></attributes>
<note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><voice>1</voice></note></measure>
<measure number="2"><note><pitch><step>D</step><octave>4</octave></pitch><duration>3</duration><voice>1</voice></note></measure>
<measure number="3"><note><pitch><step>E</step><octave>4</octave></pitch><duration>4</duration><voice>1</voice>
<notations><technical><fingering>3</fingering></technical></notations></note></measure>
</part></score-partwise>"""


def test_summary_of_homr_page():
    s = summarize(FIXTURE)
    assert s["part_count"] == 1
    assert s["parts"][0]["staves"] == 2
    assert s["measure_count"] == 33
    assert all(n > 0 for n in s["parts"][0]["notes_per_staff"])
    assert s["has_fingering"] is False


def test_rhythm_suspect_and_fingering(tmp_path):
    p = tmp_path / "a.musicxml"
    p.write_text(ONE_STAFF)
    s = summarize(p)
    assert s["rhythm_suspect_measures"] == [2]
    assert s["has_fingering"] is True
    codes = {w["code"] for w in score_warnings(s, engine_reads_fingering=True)}
    assert codes == {"no_grand_staff", "rhythm_suspect_measures"}


def test_merge_pads_missing_part(tmp_path):
    two_parts = tmp_path / "p1.musicxml"
    root = ET.parse(FIXTURE).getroot()
    part = root.find("part")
    extra = ET.fromstring(ET.tostring(part))
    extra.set("id", "P2")
    root.append(extra)
    ET.SubElement(root.find("part-list"), "score-part", id="P2")
    ET.ElementTree(root).write(two_parts)
    out = tmp_path / "merged.musicxml"
    warnings = merge_pages([two_parts, FIXTURE], out)
    assert [w["code"] for w in warnings] == ["part_count_mismatch"]
    s = summarize(out)
    assert [p["measures"] for p in s["parts"]] == [66, 66]
