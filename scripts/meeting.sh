#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -eq 1 ]] || { echo "usage: $0 /path/to/meeting-audio" >&2; exit 2; }
AUDIO="$1"
[[ -f "$AUDIO" ]] || { echo "audio file not found: $AUDIO" >&2; exit 2; }
[[ -f .runtime-secrets/meeting_api_token ]] || { echo "missing meeting API token; run ./scripts/bootstrap.sh" >&2; exit 1; }

TOKEN="$(tr -d '\r\n' < .runtime-secrets/meeting_api_token)"
PORT="${MEETINGS_HOST_PORT:-}"
if [[ -z "$PORT" && -f .env ]]; then
  PORT="$(python3 - <<'PY'
from pathlib import Path
for raw in Path('.env').read_text().splitlines():
    if raw.startswith('MEETINGS_HOST_PORT='):
        print(raw.split('=', 1)[1].strip().strip('"\''))
        break
PY
)"
fi
PORT="${PORT:-8091}"
BASE="http://127.0.0.1:${PORT}"

for _ in $(seq 1 60); do
  if curl -fsS "$BASE/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "$BASE/health" >/dev/null || { echo "meeting service not ready at $BASE" >&2; exit 1; }

AUDIO_NAME="$(basename "$AUDIO")"
stem="${AUDIO_NAME%.*}"
TITLE="${MEETING_TITLE:-$stem}"
PARTICIPANTS="${MEETING_PARTICIPANTS:-}"
VOCAB="${MEETING_VOCAB:-}"
SPEAKER_MAP="${MEETING_SPEAKER_MAP:-}"
DIARIZE="${MEETING_DIARIZE:-1}"
REQUIRE_DIARIZATION="${MEETING_REQUIRE_DIARIZATION:-0}"
NORMALIZE="${MEETING_NORMALIZE:-1}"
SUMMARY="${MEETING_SUMMARY:-1}"
RETAIN_AUDIO="${MEETING_RETAIN_AUDIO:-0}"
DEBUG_LLM_RESPONSES="${MEETING_DEBUG_LLM_RESPONSES:-0}"
WAIT="${MEETING_WAIT:-1}"

response="$(mktemp)"
trap 'rm -f "$response" "$response.artifacts"' EXIT

curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "audio=@${AUDIO}" \
  -F "title=${TITLE}" \
  -F "source=cli" \
  -F "participants=${PARTICIPANTS}" \
  -F "vocabulary=${VOCAB}" \
  -F "speaker_map=${SPEAKER_MAP}" \
  -F "diarize=${DIARIZE}" \
  -F "require_diarization=${REQUIRE_DIARIZATION}" \
  -F "normalize=${NORMALIZE}" \
  -F "summary=${SUMMARY}" \
  -F "retain_audio=${RETAIN_AUDIO}" \
  -F "debug_llm_responses=${DEBUG_LLM_RESPONSES}" \
  "$BASE/v1/meetings" > "$response"

JOB_ID="$(python3 - "$response" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['id'])
PY
)"

echo "Meeting ID: $JOB_ID"
echo "Status: queued"

if [[ "$WAIT" =~ ^(0|false|no|off)$ ]]; then
  echo "Check: make meeting-show ID=$JOB_ID"
  exit 0
fi

while true; do
  curl -fsS -H "Authorization: Bearer ${TOKEN}" "$BASE/v1/meetings/$JOB_ID" > "$response"
  status="$(python3 - "$response" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('status', 'unknown'))
PY
)"
  case "$status" in
    queued|processing)
      printf '\rStatus: %-12s' "$status"
      sleep 2
      ;;
    draft|published)
      printf '\rStatus: %-12s\n' "$status"
      break
      ;;
    failed)
      printf '\rStatus: failed      \n' >&2
      python3 - "$response" <<'PY' >&2
import json, sys
job=json.load(open(sys.argv[1]))
print(job.get('error') or 'meeting processing failed')
PY
      fail_root="artifacts/meetings/$JOB_ID"
      mkdir -p "$fail_root"
      if curl -fsS -H "Authorization: Bearer ${TOKEN}" \
          "$BASE/v1/meetings/$JOB_ID/artifacts/worker.log" \
          -o "$fail_root/worker.log" 2>/dev/null; then
        echo "Worker log: $fail_root/worker.log" >&2
      fi
      exit 1
      ;;
    *)
      echo >&2
      echo "unexpected meeting status: $status" >&2
      cat "$response" >&2
      exit 1
      ;;
  esac
done

ROOT="artifacts/meetings/$JOB_ID"
mkdir -p "$ROOT"
python3 - "$response" <<'PY' > "$response.artifacts"
import json, sys
for name in json.load(open(sys.argv[1])).get('artifacts', []):
    if name and '/' not in name and not name.startswith('.'):
        print(name)
PY
while IFS= read -r artifact; do
  [[ -n "$artifact" ]] || continue
  curl -fsS \
    -H "Authorization: Bearer ${TOKEN}" \
    "$BASE/v1/meetings/$JOB_ID/artifacts/$artifact" \
    -o "$ROOT/$artifact"
done < "$response.artifacts"
rm -f "$response.artifacts"

echo "Artifacts:    $ROOT/"
echo "Raw:          $ROOT/raw_transcript.md"
echo "Normalized:   $ROOT/normalized_transcript.md"
echo "Corrections:  $ROOT/normalization.json"
echo "Summary:      $ROOT/summary.md"
echo "Record:       $ROOT/meeting.json"
echo "Review this draft before publishing it to knowledge."
