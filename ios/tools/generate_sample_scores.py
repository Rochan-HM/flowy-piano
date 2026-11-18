#!/usr/bin/env python3
"""Generates the bundled public-domain sample scores and the test fixtures.

Outputs:
  IndianPiano/Resources/Songs/*.musicxml     bundled songs (with fingerings)
  IndianPianoTests/Fixtures/minuet-in-g.mxl  compressed MusicXML fixture
  IndianPianoTests/Fixtures/two-hands.mid    format-1 MIDI fixture (RH + LH tracks)

Run from the repository root:  python3 tools/generate_sample_scores.py
"""

import os
import struct
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SONGS = os.path.join(ROOT, "IndianPiano", "Resources", "Songs")
FIXTURES = os.path.join(ROOT, "IndianPianoTests", "Fixtures")

DIVISIONS = 4  # per quarter note
TYPES = {1: ("16th", False), 2: ("eighth", False), 3: ("eighth", True), 4: ("quarter", False),
         6: ("quarter", True), 8: ("half", False), 12: ("half", True), 16: ("whole", False)}
STEP_ALTER = {"#": 1, "b": -1}


def parse_pitch(text):
    """'F#4' -> ('F', 1, 4)"""
    step = text[0]
    alter = STEP_ALTER.get(text[1], 0) if len(text) > 2 else 0
    octave = int(text[-1])
    return step, alter, octave


def note_xml(pitch, duration, voice, staff, finger=None, chord=False, accidental=None):
    step, alter, octave = parse_pitch(pitch)
    note_type, dotted = TYPES[duration]
    lines = ["      <note>"]
    if chord:
        lines.append("        <chord/>")
    lines.append("        <pitch>")
    lines.append(f"          <step>{step}</step>")
    if alter:
        lines.append(f"          <alter>{alter}</alter>")
    lines.append(f"          <octave>{octave}</octave>")
    lines.append("        </pitch>")
    lines.append(f"        <duration>{duration}</duration>")
    lines.append(f"        <voice>{voice}</voice>")
    lines.append(f"        <type>{note_type}</type>")
    if dotted:
        lines.append("        <dot/>")
    if accidental:
        lines.append(f"        <accidental>{accidental}</accidental>")
    lines.append(f"        <stem>{'up' if staff == 1 else 'down'}</stem>")
    lines.append(f"        <staff>{staff}</staff>")
    if finger is not None:
        lines.append("        <notations>")
        lines.append("          <technical>")
        lines.append(f"            <fingering>{finger}</fingering>")
        lines.append("          </technical>")
        lines.append("        </notations>")
    lines.append("      </note>")
    return "\n".join(lines)


def voice_xml(events, voice, staff):
    """events: list of (pitches, duration, fingers); pitches is a str or list of str (chord)."""
    out = []
    for pitches, duration, fingers in events:
        if isinstance(pitches, str):
            pitches = [pitches]
            fingers = [fingers]
        for index, (pitch, finger) in enumerate(zip(pitches, fingers)):
            out.append(note_xml(pitch, duration, voice, staff, finger, chord=index > 0))
    return "\n".join(out)


def score_xml(title, composer, tempo, fifths, beats, beat_type, right, left=None, footnote=None):
    two_staves = left is not None
    measure_length = beats * DIVISIONS * 4 // beat_type
    measures = []
    for number, rh in enumerate(right, start=1):
        parts = [f'    <measure number="{number}">']
        if number == 1:
            parts.append("      <attributes>")
            parts.append(f"        <divisions>{DIVISIONS}</divisions>")
            parts.append(f"        <key><fifths>{fifths}</fifths></key>")
            parts.append(f"        <time><beats>{beats}</beats><beat-type>{beat_type}</beat-type></time>")
            if two_staves:
                parts.append("        <staves>2</staves>")
                parts.append('        <clef number="1"><sign>G</sign><line>2</line></clef>')
                parts.append('        <clef number="2"><sign>F</sign><line>4</line></clef>')
            else:
                parts.append("        <clef><sign>G</sign><line>2</line></clef>")
            parts.append("      </attributes>")
            parts.append('      <direction placement="above">')
            parts.append("        <direction-type>")
            parts.append(f"          <metronome><beat-unit>quarter</beat-unit><per-minute>{tempo}</per-minute></metronome>")
            parts.append("        </direction-type>")
            parts.append(f'        <sound tempo="{tempo}"/>')
            parts.append("      </direction>")
        assert sum(e[1] for e in rh) == measure_length, (title, number, "RH")
        parts.append(voice_xml(rh, 1, 1))
        if two_staves:
            lh = left[number - 1]
            assert sum(e[1] for e in lh) == measure_length, (title, number, "LH")
            parts.append(f"      <backup><duration>{measure_length}</duration></backup>")
            parts.append(voice_xml(lh, 5, 2))
        if number == len(right):
            parts.append('      <barline location="right"><bar-style>light-heavy</bar-style></barline>')
        parts.append("    </measure>")
        measures.append("\n".join(parts))

    credit = f"\n  <movement-title>{title}</movement-title>" if footnote is None else ""
    return f"""<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
<score-partwise version="4.0">
  <work>
    <work-title>{title}</work-title>
  </work>{credit}
  <identification>
    <creator type="composer">{composer}</creator>
    <rights>Public domain. Arrangement and fingering written for Indian Piano sample content.</rights>
    <encoding>
      <software>tools/generate_sample_scores.py</software>
    </encoding>
  </identification>
  <part-list>
    <score-part id="P1">
      <part-name>Piano</part-name>
    </score-part>
  </part-list>
  <part id="P1">
{chr(10).join(measures)}
  </part>
</score-partwise>
"""


Q, H, W, E, DQ, DH = 4, 8, 16, 2, 6, 12

# Twinkle, Twinkle, Little Star (C major, 4/4). RH in C position with a stretch to A.
TWINKLE_RH = [
    [("C4", Q, 1), ("C4", Q, 1), ("G4", Q, 4), ("G4", Q, 4)],
    [("A4", Q, 5), ("A4", Q, 5), ("G4", H, 4)],
    [("F4", Q, 4), ("F4", Q, 4), ("E4", Q, 3), ("E4", Q, 3)],
    [("D4", Q, 2), ("D4", Q, 2), ("C4", H, 1)],
    [("G4", Q, 5), ("G4", Q, 5), ("F4", Q, 4), ("F4", Q, 4)],
    [("E4", Q, 3), ("E4", Q, 3), ("D4", H, 2)],
    [("G4", Q, 5), ("G4", Q, 5), ("F4", Q, 4), ("F4", Q, 4)],
    [("E4", Q, 3), ("E4", Q, 3), ("D4", H, 2)],
    [("C4", Q, 1), ("C4", Q, 1), ("G4", Q, 4), ("G4", Q, 4)],
    [("A4", Q, 5), ("A4", Q, 5), ("G4", H, 4)],
    [("F4", Q, 4), ("F4", Q, 4), ("E4", Q, 3), ("E4", Q, 3)],
    [("D4", Q, 2), ("D4", Q, 2), ("C4", H, 1)],
]
# LH in C position (C3 = 5 ... G3 = 1).
TWINKLE_LH = [
    [("C3", W, 5)],
    [("F3", H, 2), ("C3", H, 5)],
    [("F3", H, 2), ("C3", H, 5)],
    [("G3", H, 1), ("C3", H, 5)],
    [("E3", H, 3), ("F3", H, 2)],
    [("C3", H, 5), ("G3", H, 1)],
    [("E3", H, 3), ("F3", H, 2)],
    [("C3", H, 5), ("G3", H, 1)],
    [("C3", W, 5)],
    [("F3", H, 2), ("C3", H, 5)],
    [("F3", H, 2), ("C3", H, 5)],
    [("G3", H, 1), ("C3", H, 5)],
]

# Ode to Joy (Beethoven), right hand only, C position.
ODE_RH = [
    [("E4", Q, 3), ("E4", Q, 3), ("F4", Q, 4), ("G4", Q, 5)],
    [("G4", Q, 5), ("F4", Q, 4), ("E4", Q, 3), ("D4", Q, 2)],
    [("C4", Q, 1), ("C4", Q, 1), ("D4", Q, 2), ("E4", Q, 3)],
    [("E4", DQ, 3), ("D4", E, 2), ("D4", H, 2)],
    [("E4", Q, 3), ("E4", Q, 3), ("F4", Q, 4), ("G4", Q, 5)],
    [("G4", Q, 5), ("F4", Q, 4), ("E4", Q, 3), ("D4", Q, 2)],
    [("C4", Q, 1), ("C4", Q, 1), ("D4", Q, 2), ("E4", Q, 3)],
    [("D4", DQ, 2), ("C4", E, 1), ("C4", H, 1)],
]

# Minuet in G (attr. Christian Petzold), first eight bars, simplified left hand. G major, 3/4.
MINUET_RH = [
    [("D5", Q, 5), ("G4", E, 1), ("A4", E, 2), ("B4", E, 3), ("C5", E, 4)],
    [("D5", Q, 5), ("G4", Q, 1), ("G4", Q, 1)],
    [("E5", Q, 3), ("C5", E, 1), ("D5", E, 2), ("E5", E, 3), ("F#5", E, 4)],
    [("G5", Q, 5), ("G4", Q, 1), ("G4", Q, 1)],
    [("C5", Q, 4), ("D5", E, 5), ("C5", E, 4), ("B4", E, 3), ("A4", E, 2)],
    [("B4", Q, 3), ("C5", E, 4), ("B4", E, 3), ("A4", E, 2), ("G4", E, 1)],
    [("F#4", Q, 2), ("G4", E, 1), ("A4", E, 2), ("B4", E, 3), ("G4", E, 1)],
    [("A4", DH, 2)],
]
MINUET_LH = [
    [(["G3", "B3"], H, [5, 3]), ("A3", Q, 4)],
    [("B3", DH, 3)],
    [("C4", DH, 2)],
    [("B3", DH, 3)],
    [("A3", DH, 4)],
    [("G3", DH, 5)],
    [("D4", H, 1), ("B3", Q, 3)],
    [("C4", Q, 2), ("B3", Q, 3), ("A3", Q, 4)],
]


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("wrote", os.path.relpath(path, ROOT))


def write_mxl(path, xml_name, xml_text):
    container = """<?xml version="1.0" encoding="UTF-8"?>
<container>
  <rootfiles>
    <rootfile full-path="%s" media-type="application/vnd.recordare.musicxml+xml"/>
  </rootfiles>
</container>
""" % xml_name
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(zipfile.ZipInfo("mimetype"), "application/vnd.recordare.musicxml")
        archive.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr(xml_name, xml_text, compress_type=zipfile.ZIP_DEFLATED)
    print("wrote", os.path.relpath(path, ROOT))


def vlq(value):
    out = [value & 0x7F]
    value >>= 7
    while value:
        out.insert(0, (value & 0x7F) | 0x80)
        value >>= 7
    return bytes(out)


def midi_track(events):
    """events: list of (tick, bytes) sorted by tick."""
    data = b""
    last = 0
    for tick, payload in sorted(events, key=lambda e: e[0]):
        data += vlq(tick - last) + payload
        last = tick
    data += vlq(0) + b"\xff\x2f\x00"
    return b"MTrk" + struct.pack(">I", len(data)) + data


def write_midi(path):
    """Format 1, 480 ticks per quarter, 120 bpm: conductor track, RH track, LH track."""
    tpq = 480
    conductor = [(0, b"\xff\x03" + vlq(len(b"Two Hands Test")) + b"Two Hands Test"),
                 (0, b"\xff\x51\x03" + (500000).to_bytes(3, "big")),
                 (0, b"\xff\x58\x04\x04\x02\x18\x08")]
    rh_notes = [60, 62, 64, 65]
    rh = [(0, b"\xff\x03\x0bRight Piano")]
    for index, key in enumerate(rh_notes):
        rh.append((index * tpq, bytes([0x90, key, 90])))
        rh.append(((index + 1) * tpq - 10, bytes([0x80, key, 0])))
    lh = [(0, b"\xff\x03\x0aLeft Piano")]
    lh.append((0, bytes([0x91, 48, 80])))
    lh.append((2 * tpq, bytes([0x91, 48, 0])))  # note-on velocity 0 = note-off
    lh.append((2 * tpq, bytes([0x91, 43, 80])))
    lh.append((4 * tpq, bytes([0x81, 43, 0])))
    header = b"MThd" + struct.pack(">IHHH", 6, 1, 3, tpq)
    with open(path, "wb") as handle:
        handle.write(header + midi_track(conductor) + midi_track(rh) + midi_track(lh))
    print("wrote", os.path.relpath(path, ROOT))


def main():
    twinkle = score_xml("Twinkle, Twinkle, Little Star", "Traditional", 92, 0, 4, 4, TWINKLE_RH, TWINKLE_LH)
    ode = score_xml("Ode to Joy", "Ludwig van Beethoven", 100, 0, 4, 4, ODE_RH)
    minuet = score_xml("Minuet in G (simplified)", "Christian Petzold (attr.)", 96, 1, 3, 4, MINUET_RH, MINUET_LH)
    write(os.path.join(SONGS, "twinkle-twinkle.musicxml"), twinkle)
    write(os.path.join(SONGS, "ode-to-joy.musicxml"), ode)
    write(os.path.join(SONGS, "minuet-in-g.musicxml"), minuet)
    os.makedirs(FIXTURES, exist_ok=True)
    write_mxl(os.path.join(FIXTURES, "minuet-in-g.mxl"), "score.musicxml", minuet)
    no_container = os.path.join(FIXTURES, "ode-no-container.mxl")
    with zipfile.ZipFile(no_container, "w") as archive:
        archive.writestr("ode-to-joy.xml", ode, compress_type=zipfile.ZIP_DEFLATED)
    print("wrote", os.path.relpath(no_container, ROOT))
    write_midi(os.path.join(FIXTURES, "two-hands.mid"))


if __name__ == "__main__":
    main()
