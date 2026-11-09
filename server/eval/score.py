"""Score recognized MusicXML against ground truth (MIDI or MusicXML), per hand.

    python eval/score.py --truth testdata/pieces/mutopia-burgmuller-arabesque/truth.mid out.musicxml

Several predictions (one per page) or several truth files (one per movement, `--truth` repeated)
are concatenated in the given order. Metrics, per staff and combined:

- pitch_f1: F1 of the longest common subsequence of note pitches (chords flattened low to
  high, tied notes merged), i.e. which notes were read, in the right order.
- rhythm_f1: the same with (pitch, duration) pairs.
- hands_ok: the prediction has two staves and the upper/lower staff of the truth align best with
  the upper/lower staff of the prediction (not swapped or merged).
- measures: measure count of the prediction vs. the truth.
- fingering: fingerings in the prediction, and (for MusicXML truth with fingerings) how many
  truth fingerings were read on a matched note.
"""

from __future__ import annotations

import argparse
import json
import math
import warnings
from dataclasses import dataclass, field
from pathlib import Path

import music21 as m21

warnings.filterwarnings("ignore")


@dataclass
class Tok:
    pitch: int
    dur: float
    finger: int | None = None


@dataclass
class Staves:
    staves: list[list[Tok]] = field(default_factory=list)
    measures: int = 0
    fingerings: int = 0


def _fingers(el: m21.note.GeneralNote) -> list[int]:
    out = []
    for a in getattr(el, "articulations", []):
        if isinstance(a, m21.articulations.Fingering):
            try:
                out.append(int(str(a.fingerNumber).strip()[0]))
            except (ValueError, IndexError):
                pass
    return out


def _staff_tokens(staff: m21.stream.Stream) -> tuple[list[Tok], int]:
    events = []
    nfing = 0
    for el in staff.flatten().notes:
        if el.duration.isGrace:
            continue
        dur = round(float(el.quarterLength) * 12) / 12
        notes = list(el.notes) if isinstance(el, m21.chord.Chord) else [el]
        fingers = _fingers(el)
        if not fingers and len(notes) > 1:
            fingers = [f for n in notes for f in _fingers(n)]
        nfing += len(fingers)
        for i, n in enumerate(notes):
            f = fingers[i] if len(fingers) == len(notes) else (fingers[0] if len(notes) == 1 and fingers else None)
            events.append((float(el.offset), n.pitch.midi, dur, f))
    events.sort(key=lambda e: (e[0], e[1]))
    return [Tok(p, d, f) for _, p, d, f in events], nfing


def _parts_as_staves(score: m21.stream.Score) -> list[m21.stream.Stream]:
    parts = list(score.parts)
    if not parts:
        return [score]
    return parts


def load(path: Path, measures: tuple[int, int] | None = None) -> Staves:
    score = m21.converter.parse(str(path))
    if isinstance(score, m21.stream.Opus):
        score = score.scores[0]
    if measures:
        score = score.measures(*measures)
    if path.suffix.lower() not in (".mid", ".midi"):
        score = score.stripTies()
    result = Staves()
    for part in _parts_as_staves(score):
        toks, nf = _staff_tokens(part)
        if not toks and path.suffix.lower() in (".mid", ".midi"):
            continue
        result.staves.append(toks)
        result.fingerings += nf
    first = _parts_as_staves(score)[0]
    measures = first.getElementsByClass(m21.stream.Measure)
    if path.suffix.lower() in (".mid", ".midi"):
        ts = score.recurse().getElementsByClass(m21.meter.TimeSignature).first()
        bar = ts.barDuration.quarterLength if ts else 4.0
        result.measures = math.ceil(round(score.highestTime / bar, 3))
    else:
        result.measures = len(measures)
    return result


def concat(items: list[Staves]) -> Staves:
    out = Staves()
    n = max((len(i.staves) for i in items), default=0)
    out.staves = [[] for _ in range(n)]
    for it in items:
        for k, st in enumerate(it.staves):
            out.staves[k].extend(st)
        out.measures += it.measures
        out.fingerings += it.fingerings
    return out


def lcs_pairs(a: list, b: list) -> list[tuple[int, int]]:
    n, m = len(a), len(b)
    if not n or not m:
        return []
    prev = [0] * (m + 1)
    rows = []
    for i in range(1, n + 1):
        cur = [0] * (m + 1)
        ai = a[i - 1]
        for j in range(1, m + 1):
            cur[j] = prev[j - 1] + 1 if ai == b[j - 1] else (prev[j] if prev[j] >= cur[j - 1] else cur[j - 1])
        rows.append(cur)
        prev = cur
    pairs = []
    i, j = n, m
    while i > 0 and j > 0:
        if a[i - 1] == b[j - 1]:
            pairs.append((i - 1, j - 1))
            i -= 1
            j -= 1
        elif (rows[i - 2][j] if i > 1 else 0) >= rows[i - 1][j - 1]:
            i -= 1
        else:
            j -= 1
    return pairs[::-1]


def f1(matched: int, n_truth: int, n_pred: int) -> float:
    if n_truth == 0 and n_pred == 0:
        return 1.0
    if matched == 0:
        return 0.0
    p, r = matched / n_pred, matched / n_truth
    return 2 * p * r / (p + r)


def score(truth: Staves, pred: Staves) -> dict:
    t_up = truth.staves[0] if truth.staves else []
    t_lo = truth.staves[1] if len(truth.staves) > 1 else []
    p_staves = pred.staves
    res: dict = {
        "pred_staves": len(p_staves),
        "truth_measures": truth.measures,
        "pred_measures": pred.measures,
        "pred_fingerings": pred.fingerings,
        "truth_fingerings": truth.fingerings,
    }

    def pitch_match(t, p):
        return len(lcs_pairs([x.pitch for x in t], [x.pitch for x in p]))

    if len(p_staves) >= 2:
        p_up, p_lo = p_staves[0], p_staves[1]
        if len(p_staves) > 2:
            # extra staves (e.g. a system split into parts): fold them in by best fit
            for extra in p_staves[2:]:
                if pitch_match(t_up, extra) >= pitch_match(t_lo, extra):
                    p_up = p_up + extra
                else:
                    p_lo = p_lo + extra
        direct = pitch_match(t_up, p_up) + pitch_match(t_lo, p_lo)
        swapped = pitch_match(t_up, p_lo) + pitch_match(t_lo, p_up)
        res["hands_ok"] = direct >= swapped and len(p_staves) == 2
    else:
        p_up = p_staves[0] if p_staves else []
        p_lo = []
        res["hands_ok"] = False

    total = {"pitch": 0, "rhythm": 0, "t": 0, "p": 0}
    finger_hits = finger_truth = 0
    for name, t, p in (("upper", t_up, p_up), ("lower", t_lo, p_lo)):
        pp = lcs_pairs([x.pitch for x in t], [x.pitch for x in p])
        rp = lcs_pairs([(x.pitch, x.dur) for x in t], [(x.pitch, x.dur) for x in p])
        res[f"{name}_pitch_f1"] = round(f1(len(pp), len(t), len(p)), 3)
        res[f"{name}_rhythm_f1"] = round(f1(len(rp), len(t), len(p)), 3)
        res[f"{name}_notes"] = [len(t), len(p)]
        total["pitch"] += len(pp)
        total["rhythm"] += len(rp)
        total["t"] += len(t)
        total["p"] += len(p)
        for i, j in pp:
            if t[i].finger is not None:
                finger_truth += 1
                finger_hits += int(p[j].finger == t[i].finger)
    res["pitch_f1"] = round(f1(total["pitch"], total["t"], total["p"]), 3)
    res["rhythm_f1"] = round(f1(total["rhythm"], total["t"], total["p"]), 3)
    if truth.fingerings:
        res["fingering_recall_on_matched_notes"] = round(finger_hits / finger_truth, 3) if finger_truth else 0.0
    return res


def agreement(a: Staves, b: Staves) -> dict:
    """Staff-by-staff pitch F1 between two readings with any number of staves."""
    matched = total_a = total_b = 0
    for k in range(max(len(a.staves), len(b.staves))):
        sa = [t.pitch for t in a.staves[k]] if k < len(a.staves) else []
        sb = [t.pitch for t in b.staves[k]] if k < len(b.staves) else []
        matched += len(lcs_pairs(sa, sb))
        total_a += len(sa)
        total_b += len(sb)
    return {"staves": [len(a.staves), len(b.staves)], "pitch_f1": round(f1(matched, total_a, total_b), 3)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--truth", action="append", type=Path, required=True, help="repeat for several files")
    parser.add_argument("--truth-measures", help="only these measures of the truth, e.g. 1-30 (MusicXML truth)")
    parser.add_argument("pred", nargs="+", type=Path)
    args = parser.parse_args()
    rng = tuple(int(x) for x in args.truth_measures.split("-")) if args.truth_measures else None
    truth = concat([load(p, rng) for p in args.truth])
    pred = concat([load(p) for p in args.pred])
    print(json.dumps(score(truth, pred), indent=2))


if __name__ == "__main__":
    main()
