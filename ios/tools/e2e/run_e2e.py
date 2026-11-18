#!/usr/bin/env python3
"""End-to-end lesson tests in the iOS Simulator, driven by rendered piano audio.

For each case: load a score in the app (bundled, imported, or recognized from a PDF/photo by the
OMR server), export the lesson steps, write a performance that plays them (chords together) with
deliberate wrong notes, render it with a sampled grand piano, and play it into the app's
microphone pipeline. The app logs one line per input; the run checks that every step advanced,
that each wrong note was flagged with the right correction, and that nothing else was flagged.

Audio input:
  --input file       stream the WAV through the app's mic analysis (`-micFile`, no mic needed)
  --input blackhole  play the WAV into BlackHole 2ch while the app listens on the real mic input
                     (needs BlackHole as the default input and Simulator allowed to use the mic)

Usage: python3 tools/e2e/run_e2e.py [--input file|blackhole] [--case NAME ...] [--video NAME] [--device UDID]
Results: /tmp/indianpiano-e2e/results.json and a Markdown table on stdout.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.dirname(os.path.dirname(HERE))
REPO = os.path.dirname(IOS)
WORK = "/tmp/indianpiano-e2e"
BUNDLE = "com.rochan.indianpiano"
LOG = os.path.join(WORK, "app.log")

# (name, source, hand mode, notation, Sa, steps to play, steps that get a wrong note first)
CASES = [
    dict(name="twinkle-rh-western", song="twinkle", hand="right", notation="western", sa="C", steps=14, wrong=[3, 9]),
    dict(name="twinkle-rh-quiet-30db", song="twinkle", hand="right", notation="western", sa="C", steps=14, wrong=[6], gain=-30),
    dict(name="twinkle-lh-carnatic-sa-c", song="twinkle", hand="left", notation="carnatic", sa="C", steps=10, wrong=[2]),
    dict(name="twinkle-both-carnatic-sa-c", song="twinkle", hand="both", notation="carnatic", sa="C", steps=12, wrong=[4]),
    dict(name="minuet-both-carnatic-sa-g", song="minuet-in-g", hand="both", notation="carnatic", sa="G", steps=12, wrong=[3, 8]),
    dict(name="fur-elise-rh-fingered", file="testdata/musicxml/fur-elise-fingered.mxl", hand="right", notation="western", sa="C", steps=16, wrong=[5]),
    dict(name="fur-elise-lh-carnatic-sa-a", file="testdata/musicxml/fur-elise-fingered.mxl", hand="left", notation="carnatic", sa="A", steps=10, wrong=[3]),
    dict(name="bach-minuet-mxl-both", file="testdata/musicxml/bach-minuet-in-g.mxl", hand="both", notation="western", sa="C", steps=12, wrong=[6]),
    dict(name="prelude-c-both", file="testdata/musicxml/bach-prelude-c-bwv846.mxl", hand="both", notation="carnatic", sa="C", steps=16, wrong=[7]),
    dict(name="la-candeur-midi-rh", file="testdata/midi/burgmuller-la-candeur.mid", hand="right", notation="western", sa="C", steps=12, wrong=[4]),
    dict(name="la-candeur-pdf-scan-both", recognize="testdata/sheets/burgmuller-la-candeur.pdf", hand="both", notation="carnatic", sa="C", steps=12, wrong=[5]),
    dict(name="la-candeur-png-scan-lh", recognize="testdata/sheets/burgmuller-la-candeur-p1.png", hand="left", notation="carnatic", sa="C", steps=10, wrong=[3]),
    dict(name="clementi-midi-both", file="testdata/midi/clementi-op36-1.mid", hand="both", notation="western", sa="C", steps=14, wrong=[5]),
    dict(name="ode-easy-mxl-rh-sa-d", file="testdata/musicxml/ode-to-joy-easy.mxl", hand="right", notation="carnatic", sa="D", steps=12, wrong=[7]),
    dict(name="minuet-photo-scan-rh", recognize="server/testdata/pieces/mutopia-bach-minuet-g/photo-mild.jpg", hand="right", notation="western", sa="C", steps=12, wrong=[2]),
]

STEP_GAP = 0.85
NOTE_LENGTH = 0.55
WRONG_LEAD = 0.75


def sh(*args, check=True, capture=True):
    return subprocess.run(args, check=check, capture_output=capture, text=True)


def simctl(*args, check=True):
    return sh("xcrun", "simctl", *args, check=check)


DEVICE = "booted"


def pick_device(requested=None):
    """The Simulator to drive: `simctl ... booted` picks an arbitrary one when several are booted."""
    if requested:
        return requested
    booted = json.loads(sh("xcrun", "simctl", "list", "devices", "booted", "-j").stdout)["devices"]
    udids = [device["udid"] for devices in booted.values() for device in devices if device.get("state") == "Booted"]
    if len(udids) == 1:
        return udids[0]
    raise SystemExit(f"{len(udids)} simulators are booted; pass --device <udid>" if udids else "no simulator is booted")


def app_args(case, recognition):
    args = ["-handMode", case["hand"], "-practiceMode", "wait", "-notation", case["notation"],
            "-saPitchClass", case["sa"], "-showFingers", "YES", "-sound", "NO", "-micOctaveTolerant", "YES"]
    if recognition:
        args += ["-recognitionEnabled", "YES", "-recognitionURL", recognition["url"], "-recognitionToken", recognition["token"]]
    return args


def launch(args):
    simctl("terminate", DEVICE, BUNDLE, check=False)
    out = simctl("launch", DEVICE, BUNDLE, *args).stdout
    return int(out.strip().split(":")[-1])


def log_lines(pid):
    with open(LOG, errors="replace") as handle:
        return [line for line in handle if f"[{pid}:" in line]


def wait_for(pid, pattern, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if any(re.search(pattern, line) for line in log_lines(pid)):
            return True
        time.sleep(0.5)
    return False


def stage(path):
    """The Simulator can't read OneDrive-backed folders, so copy inputs to /tmp."""
    source = os.path.join(REPO, path) if not os.path.isabs(path) else path
    if not os.path.exists(source):
        alt = os.path.join("/tmp/rp-omr", path)
        source = alt if os.path.exists(alt) else source
    target = os.path.join(WORK, "inputs", os.path.basename(path))
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copy(source, target)
    return target


def load_case(case, recognition):
    """Loads the case's score in the app and exports its lesson steps. Returns the steps JSON."""
    steps_path = os.path.join(WORK, case["name"], "steps.json")
    os.makedirs(os.path.dirname(steps_path), exist_ok=True)
    if os.path.exists(steps_path):
        os.remove(steps_path)
    args = app_args(case, recognition) + ["-exportLessonSteps", steps_path]
    if "song" in case:
        args += ["-song", case["song"]]
    elif "file" in case:
        args += ["-importPath", stage(case["file"])]
    else:
        args += ["-recognizeFile", stage(case["recognize"])]
    pid = launch(args)
    timeout = 120 if "recognize" in case else 30
    if not wait_for(pid, r"Exported \d+ lesson steps", timeout):
        raise RuntimeError("the app didn't export lesson steps (import or recognition failed?)")
    with open(steps_path) as handle:
        return json.load(handle)


def wrong_note_for(step_notes, neighbours):
    taken = {m % 12 for m in step_notes + neighbours}
    top = max(step_notes)
    for delta in (1, 2, -1, -2, 3, -3, 4, 5):
        candidate = top + delta
        if candidate % 12 not in taken:
            return candidate
    return top + 6


def make_plan(lesson, case):
    steps = lesson["steps"][: case["steps"]]
    events, expected = [], []
    t = 1.0
    for index, step in enumerate(steps):
        midis = [n["midi"] for n in step["notes"]]
        if index in case["wrong"]:
            neighbours = [n["midi"] for s in lesson["steps"][max(0, index - 1): index + 2] for n in s["notes"]]
            wrong = wrong_note_for(midis, neighbours)
            events.append(dict(time=t, midis=[wrong], duration=NOTE_LENGTH, velocity=85))
            expected.append(dict(kind="wrong", step=index, played=wrong, expected=sorted(midis)))
            t += WRONG_LEAD
        events.append(dict(time=t, midis=midis, duration=NOTE_LENGTH, velocity=85))
        expected.append(dict(kind="advance", step=index))
        t += STEP_GAP
    return dict(events=events, tail=1.5), expected, steps


def render(plan, folder, gain):
    plan_path = os.path.join(folder, "performance.json")
    wav_path = os.path.join(folder, "performance.wav")
    with open(plan_path, "w") as handle:
        json.dump(plan, handle, indent=1)
    raw = os.path.join(folder, "performance-raw.wav")
    sh("swift", os.path.join(HERE, "render_piano.swift"), plan_path, raw)
    # Normalise the peak (default -6 dBFS, roughly a piano a metre from a phone microphone).
    sh("sox", raw, wav_path, "gain", "-n", str(gain))
    return wav_path


def parse_events(pid):
    events = []
    for line in log_lines(pid):
        match = re.search(r"LESSON source=(\S+) played=(\S+) result=(\S+) step=(\d+)->(\d+)/(\d+) expected=(\S*) labels=(\S*)", line)
        if match:
            source, played, result, before, after, total, expected, labels = match.groups()
            midis = sorted(int(re.match(r"\d+", item).group()) for item in expected.split(",") if item)
            events.append(dict(source=source, played=played, result=result, before=int(before), after=int(after),
                               expected=midis, labels=labels))
    return events


def check(expected, events, steps):
    advanced = {e["before"] for e in events if e["result"] == "advance" and e["after"] == e["before"] + 1}
    wrongs = [e for e in events if e["result"] == "wrong"]
    problems = []
    for index in range(len(steps)):
        if index not in advanced:
            problems.append(f"step {index} never advanced")
    planned_wrong = [x for x in expected if x["kind"] == "wrong"]
    matched = 0
    for plan in planned_wrong:
        hit = [w for w in wrongs if w["before"] == plan["step"]]
        if not hit:
            problems.append(f"wrong note {plan['played']} at step {plan['step']} not flagged")
            continue
        if any(w["expected"] == plan["expected"] or set(w["expected"]) <= set(plan["expected"]) for w in hit):
            matched += 1
        else:
            problems.append(f"step {plan['step']}: correction {hit[0]['expected']} != {plan['expected']}")
    planned_steps = {p["step"] for p in planned_wrong}
    extra = [w for w in wrongs if w["before"] not in planned_steps]
    for w in extra:
        problems.append(f"unexpected wrong at step {w['before']}: heard {w['played']}, expected {w['expected']}")
    chord_steps = sum(1 for s in steps if len(s["notes"]) > 1)
    via_chord = sum(1 for e in events if e["source"] == "mic-chord" and e["result"] == "advance")
    return dict(
        advanced=len(advanced & set(range(len(steps)))), steps=len(steps),
        wrong_flagged=matched, wrong_planned=len(planned_wrong), extra_wrong=len(extra),
        chord_steps=chord_steps, chord_matches=via_chord, problems=problems, ok=not problems,
    )


def play_blackhole(wav):
    sh("sox", wav, "-t", "coreaudio", "BlackHole 2ch")


def audio_device(kind):
    return sh("SwitchAudioSource", "-c", "-t", kind).stdout.strip()


def set_audio_device(kind, name):
    sh("SwitchAudioSource", "-t", kind, "-s", name)


def run_case(case, args, recognition):
    folder = os.path.join(WORK, case["name"])
    os.makedirs(folder, exist_ok=True)
    lesson = load_case(case, recognition)
    plan, expected, steps = make_plan(lesson, case)
    wav = render(plan, folder, case.get("gain", -6))
    duration = plan["events"][-1]["time"] + 2.5

    base = app_args(case, recognition)  # no -song: the app reopens the song it just loaded
    video = None
    if args.video == case["name"]:
        video_path = os.path.join(WORK, f"{case['name']}.mp4")
        if os.path.exists(video_path):
            os.remove(video_path)
        video = subprocess.Popen(["xcrun", "simctl", "io", DEVICE, "recordVideo", "--codec=h264", "--force", video_path],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.5)
    if args.input == "file":
        pid = launch(base + ["-micFile", wav, "-micFileDelayMs", "800"])
        time.sleep(duration + 2)
    else:
        pid = launch(base + ["-startMic", "YES"])
        if not wait_for(pid, r"Microphone started", 15):
            raise RuntimeError("the app couldn't open the microphone (is Simulator allowed to use it?)")
        time.sleep(1.5)
        play_blackhole(wav)
        time.sleep(2.5)
    if video:
        time.sleep(1)
        video.send_signal(2)
        video.wait(timeout=20)
    simctl("io", DEVICE, "screenshot", os.path.join(folder, "end.png"), check=False)
    events = parse_events(pid)
    result = check(expected, events, steps)
    detections = sum(1 for line in log_lines(pid) if "Detected note" in line)
    result.update(name=case["name"], title=lesson["title"], hand=case["hand"], notation=f"{case['notation']} Sa={case['sa']}",
                  input=args.input, detections=detections,
                  sample_labels=" ".join(e["labels"] for e in events[:4] if e["labels"]))
    with open(os.path.join(folder, "events.json"), "w") as handle:
        json.dump(dict(expected=expected, events=events, result=result), handle, indent=1)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", choices=["file", "blackhole"], default="file")
    parser.add_argument("--case", action="append", help="run only these cases")
    parser.add_argument("--video", help="record the Simulator screen during this case")
    parser.add_argument("--device", help="Simulator UDID (needed when several simulators are booted)")
    parser.add_argument("--omr-url", default="http://localhost:8000")
    parser.add_argument("--omr-token", default=os.environ.get("OMR_API_TOKEN", "dev-token"))
    args = parser.parse_args()
    global DEVICE
    DEVICE = pick_device(args.device)

    os.makedirs(WORK, exist_ok=True)
    open(LOG, "w").close()
    logger = subprocess.Popen(["xcrun", "simctl", "spawn", DEVICE, "log", "stream", "--level", "info", "--style", "compact",
                               "--predicate", f'subsystem == "{BUNDLE}"'], stdout=open(LOG, "a"), stderr=subprocess.DEVNULL)
    time.sleep(1.5)
    recognition = dict(url=args.omr_url, token=args.omr_token)
    results = []
    original_devices = None
    if args.input == "blackhole":
        # Only the default input changes (the Simulator listens on it); playback goes straight to
        # BlackHole, so the user's output device and volume are never touched.
        original_devices = dict(input=audio_device("input"), output=audio_device("output"))
        print(f"audio devices before the run: {original_devices}", flush=True)
        set_audio_device("input", "BlackHole 2ch")
    try:
        for case in CASES:
            if args.case and case["name"] not in args.case:
                continue
            print(f"== {case['name']}", flush=True)
            try:
                result = run_case(case, args, recognition)
            except Exception as error:  # noqa: BLE001 - report and continue with the next case
                result = dict(name=case["name"], ok=False, problems=[str(error)], hand=case["hand"],
                              notation=f"{case['notation']} Sa={case['sa']}", input=args.input)
            results.append(result)
            print(json.dumps(result), flush=True)
    finally:
        logger.terminate()
        simctl("terminate", DEVICE, BUNDLE, check=False)
        if original_devices:
            set_audio_device("input", original_devices["input"])
            if audio_device("output") != original_devices["output"]:
                set_audio_device("output", original_devices["output"])
            print(f"audio devices restored: input={audio_device('input')}, output={audio_device('output')}", flush=True)
    with open(os.path.join(WORK, f"results-{args.input}.json"), "w") as handle:
        json.dump(results, handle, indent=1)

    print("\n| Case | Hands | Notation | Steps advanced | Wrong notes flagged | Extra flags | Chord steps (chroma) | Result |")
    print("|---|---|---|---|---|---|---|---|")
    for r in results:
        if "steps" in r:
            print(f"| {r['name']} | {r['hand']} | {r['notation']} | {r['advanced']}/{r['steps']} | {r['wrong_flagged']}/{r['wrong_planned']} "
                  f"| {r['extra_wrong']} | {r['chord_steps']} ({r['chord_matches']}) | {'pass' if r['ok'] else 'FAIL'} |")
        else:
            print(f"| {r['name']} | {r['hand']} | {r['notation']} | - | - | - | - | FAIL: {r['problems'][0]} |")
    sys.exit(0 if all(r["ok"] for r in results) else 1)


if __name__ == "__main__":
    main()
