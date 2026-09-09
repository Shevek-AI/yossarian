#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

output="$(
  MEETING_TITLE="Meeting smoke" \
  MEETING_DIARIZE=0 \
  MEETING_SUMMARY=0 \
  MEETING_NORMALIZE=0 \
  ./scripts/meeting.sh fixtures/audio/transcription_smoke.wav
)"
printf '%s\n' "$output"

job_id="$(printf '%s\n' "$output" | sed -n 's/^Meeting ID: //p' | head -1)"
[[ -n "$job_id" ]] || { echo "meeting smoke could not determine job id" >&2; exit 1; }
root="artifacts/meetings/$job_id"

python3 - "$root" "$job_id" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
job_id = sys.argv[2]
raw = (root / 'raw_transcript.md').read_text().lower()
normalized = (root / 'normalized_transcript.md').read_text().lower()
transcript = (root / 'transcript.md').read_text().lower()
normalization = json.loads((root / 'normalization.json').read_text())
record = json.loads((root / 'meeting.json').read_text())
summary = (root / 'summary.md').read_text().lower()
for expected in ('local', 'runtime', 'meeting'):
    assert expected in raw, (expected, raw)
assert normalized == transcript
assert normalization['applied'] == []
assert record['diarization_requested'] is False
assert record['raw_segments']
assert record['segments']
assert record['schema_version'] == 2
assert record['meeting_id'] == job_id
assert 'summary generation disabled' in summary
assert job_id.startswith('mtg_')
print('Meeting service workflow smoke: PASS')
PY
