#!/bin/zsh
# Live microphone check in the iOS Simulator: launches the app listening, plays piano-like tones
# through the Mac speakers (C4 C4 G4 G4, a wrong D4, then A4 A4) and prints what the app heard.
#
# One-time prerequisite: macOS must let Simulator use the microphone. The first run shows a macOS
# prompt — click Allow (or enable Simulator in System Settings › Privacy & Security › Microphone).
# Until then CoreAudio in the Simulator blocks and aborts the app when the mic is opened.
#
# Usage: tools/mic_smoke_test.sh [simulator-udid]   (defaults to the booted simulator)
set -euo pipefail
cd "$(dirname "$0")/.."

SIM=${1:-booted}
BUNDLE=com.rochan.indianpiano
LOG=/tmp/indianpiano-mic-log.txt
TONES=/tmp/indianpiano-tones.wav

python3 tools/make_test_tones.py "$TONES" C4 C4 G4 G4 D4 A4 A4
xcrun simctl privacy "$SIM" grant microphone "$BUNDLE"
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true

xcrun simctl spawn "$SIM" log stream --level info --predicate "subsystem == \"$BUNDLE\"" > "$LOG" 2>&1 &
LOG_PID=$!
trap 'kill $LOG_PID 2>/dev/null || true' EXIT

xcrun simctl launch "$SIM" "$BUNDLE" -song twinkle -handMode right -practiceMode wait -startMic YES >/dev/null
echo "Waiting for the microphone…"
for _ in {1..20}; do
  grep -q "Microphone started" "$LOG" && break
  sleep 0.5
done
if ! grep -q "Microphone started" "$LOG"; then
  echo "The app didn't open the microphone. Check the macOS microphone prompt for Simulator." >&2
  exit 1
fi

afplay "$TONES"
sleep 1
echo "Notes the app detected (expected 60 60 67 67 62 69 69):"
grep -o "Detected note [0-9]*" "$LOG" | awk '{print $3}' | tr '\n' ' '
echo
xcrun simctl io "$SIM" screenshot /tmp/indianpiano-mic.png >/dev/null && echo "Screenshot: /tmp/indianpiano-mic.png"
