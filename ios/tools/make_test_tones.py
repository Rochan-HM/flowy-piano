#!/usr/bin/env python3
"""Writes a WAV of piano-like tones for exercising microphone detection.

Usage: python3 tools/make_test_tones.py out.wav C4 C4 G4 G4 D4 A4
Each note sounds for 0.7 s followed by 0.35 s of silence.
"""

import math
import struct
import sys
import wave

RATE = 44100
NAMES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def midi(name):
    pitch = NAMES[name[0].upper()]
    rest = name[1:]
    if rest.startswith("#"):
        pitch += 1
        rest = rest[1:]
    elif rest.startswith("b"):
        pitch -= 1
        rest = rest[1:]
    return (int(rest) + 1) * 12 + pitch


def tone(note, seconds=0.7, gap=0.35):
    frequency = 440 * 2 ** ((midi(note) - 69) / 12)
    weights = [1.0, 0.5, 0.3, 0.18, 0.1]
    samples = []
    for index in range(int(seconds * RATE)):
        t = index / RATE
        envelope = min(1.0, t / 0.005) * math.exp(-t * 2.5)
        value = sum(w * math.sin(2 * math.pi * frequency * (k + 1) * t) for k, w in enumerate(weights))
        samples.append(0.45 * envelope * value / sum(weights))
    samples += [0.0] * int(gap * RATE)
    return samples


def main():
    out = sys.argv[1]
    notes = sys.argv[2:] or ["C4", "C4", "G4", "G4", "A4"]
    data = []
    for note in notes:
        data += tone(note)
    with wave.open(out, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in data))
    print(f"wrote {out}: {' '.join(notes)}")


if __name__ == "__main__":
    main()
