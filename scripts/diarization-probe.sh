#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -eq 1 ]] || { echo "usage: $0 /path/to/audio" >&2; exit 2; }
AUDIO="$1"
[[ -f "$AUDIO" ]] || { echo "audio file not found: $AUDIO" >&2; exit 2; }

./scripts/ensure-speech-models.sh

AUDIO_ABS="$(readlink -f "$AUDIO")"
AUDIO_NAME="$(basename "$AUDIO")"
TMP="/tmp/runtime-diarization-probe-$$"
cleanup() { docker compose exec -T speaches rm -f "$TMP" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker compose cp "$AUDIO_ABS" "speaches:$TMP" >/dev/null

docker compose exec -T -e DIARIZATION_PATH="$TMP" -e DIARIZATION_NAME="$AUDIO_NAME" speaches python3 - <<'PY'
import mimetypes
import os
from pathlib import Path
import httpx

path = Path(os.environ['DIARIZATION_PATH'])
name = os.environ['DIARIZATION_NAME']
key = os.environ['API_KEY']
content_type = mimetypes.guess_type(name)[0] or 'application/octet-stream'
with path.open('rb') as f:
    response = httpx.post(
        'http://127.0.0.1:8000/v1/audio/diarization',
        headers={'Authorization': f'Bearer {key}'},
        files={'file': (name, f, content_type)},
        data={'response_format': 'json'},
        timeout=7200,
    )
print('status:', response.status_code)
print(response.text)
response.raise_for_status()
PY
