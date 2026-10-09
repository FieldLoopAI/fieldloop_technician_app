#!/usr/bin/env bash
# Build 176 Step 1 — 5-turn TURN TIMING smoke test (run from Git Bash with
# the tablet on adb). Logging only: it reads logcat, it changes nothing.
#
#   1. Install the build, open a job, say the wake word.
#   2. Run:  bash tool/b176_turn_timing_smoke.sh
#   3. When it says GO, speak these 5 commands, one at a time, waiting for
#      each reply (speak at normal or quiet volume):
#        1) "Show me the estimate."
#        2) "Go back."
#        3) "Who is the customer?"
#        4) "Take a photo."
#        5) "Retake."
#   4. Press Enter. PASS = 5 or more TURN TIMING lines and every turn's
#      transcript has one; estimated ones are listed separately.
set -u
OUT="${TMPDIR:-/tmp}/b176_turn_timing_smoke.txt"
adb logcat -c
echo "GO — speak the 5 commands now, then press Enter."
adb logcat -v time flutter:I '*:S' > "$OUT" &
PID=$!
read -r _
kill "$PID" 2>/dev/null
transcripts=$(grep -c 'transcript_received' "$OUT")
timings=$(grep 'TURN TIMING:' "$OUT" | grep -vc 'already timed')
estimated=$(grep 'TURN TIMING:' "$OUT" | grep -c 'estimated speech end:')
echo "transcripts=$transcripts TURN_TIMING_lines=$timings (estimated=$estimated)"
grep 'TURN TIMING:' "$OUT"
if [ "$timings" -ge 5 ] && [ "$timings" -ge "$transcripts" ]; then
  echo "PASS"
else
  echo "FAIL — a turn without a TURN TIMING line; full log: $OUT"
  exit 1
fi
