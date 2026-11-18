#!/usr/bin/env python3
"""Records a Simulator lesson driven through the real microphone input (via BlackHole 2ch), with
the piano audio muxed into the video in sync.

Run `run_e2e.py --case twinkle-both-carnatic-sa-c` first: it renders the performance used here.
Only the default input device changes during the recording, and it is always restored.

Usage: python3 tools/e2e/record_live_demo.py [out.mp4] [simulator-udid]
"""

import os
import signal
import subprocess
import sys
import time

from run_e2e import pick_device

WORK = "/tmp/indianpiano-e2e/live-demo"
WAV = "/tmp/indianpiano-e2e/twinkle-both-carnatic-sa-c/performance.wav"
BUNDLE = "com.rochan.indianpiano"
APP_ARGS = ["-song", "twinkle", "-handMode", "both", "-practiceMode", "wait", "-notation", "carnatic", "-saPitchClass", "C",
            "-showFingers", "YES", "-sound", "NO", "-micOctaveTolerant", "YES", "-startMic", "YES"]


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WORK, "lesson-live-mic-with-audio.mp4")
    device = pick_device(sys.argv[2] if len(sys.argv) > 2 else None)
    os.makedirs(WORK, exist_ok=True)
    log_path = os.path.join(WORK, "app.log")
    original_input = sh("SwitchAudioSource", "-c", "-t", "input").stdout.strip()
    logger = subprocess.Popen(["xcrun", "simctl", "spawn", device, "log", "stream", "--level", "info", "--style", "compact",
                               "--predicate", f'subsystem == "{BUNDLE}"'], stdout=open(log_path, "w"), stderr=subprocess.DEVNULL)
    video = os.path.join(WORK, "video.mp4")
    try:
        sh("SwitchAudioSource", "-t", "input", "-s", "BlackHole 2ch")
        sh("xcrun", "simctl", "terminate", device, BUNDLE)
        time.sleep(1)
        sh("xcrun", "simctl", "launch", device, BUNDLE, *APP_ARGS)
        for _ in range(40):
            if "Microphone started" in open(log_path, errors="replace").read():
                break
            time.sleep(0.25)
        time.sleep(1.0)
        recorder = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo", "--codec=h264", "--force", video],
                                    stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True)
        started = None
        for line in recorder.stderr:
            if "Recording started" in line:
                started = time.time()
                break
        time.sleep(1.0)
        audio_start = time.time()
        sh("sox", WAV, "-t", "coreaudio", "BlackHole 2ch")
        time.sleep(1.5)
        recorder.send_signal(signal.SIGINT)
        recorder.wait(timeout=30)
    finally:
        sh("SwitchAudioSource", "-t", "input", "-s", original_input)
        logger.terminate()
    offset = audio_start - started
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", video, "-itsoffset", f"{offset:.3f}", "-i", WAV,
                    "-map", "0:v", "-map", "1:a", "-vf", "scale=1280:-2,fps=30", "-c:v", "libx264", "-crf", "26",
                    "-preset", "slow", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", out],
                   check=True)
    print(f"wrote {out} (audio offset {offset:.3f} s); input restored to {original_input}")


if __name__ == "__main__":
    main()
