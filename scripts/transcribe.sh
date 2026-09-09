#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/ensure-speech-models.sh

[[ $# -eq 1 ]] || { echo "usage: $0 /path/to/audio" >&2; exit 2; }
AUDIO="$1"
[[ -f "$AUDIO" ]] || { echo "audio file not found: $AUDIO" >&2; exit 2; }

ext="${AUDIO##*.}"
if [[ "$ext" == "$AUDIO" || ${#ext} -gt 8 ]]; then
  ext="audio"
fi
remote="/tmp/runtime-transcribe-$$.$ext"
cleanup() {
  docker compose exec -T speaches rm -f "$remote" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose cp "$AUDIO" "speaches:$remote" >/dev/null

docker compose exec -T -e TRANSCRIBE_PATH="$remote" speaches python3 - <<'PY'
import mimetypes
import os
from pathlib import Path

import httpx

path = Path(os.environ['TRANSCRIBE_PATH'])
model = os.environ['SPEACHES_STT_MODEL']
key = os.environ['API_KEY']
content_type = mimetypes.guess_type(path.name)[0] or 'application/octet-stream'
with path.open('rb') as f:
    response = httpx.post(
        'http://127.0.0.1:8000/v1/audio/transcriptions',
        headers={'Authorization': f'Bearer {key}'},
        files={'file': (path.name, f, content_type)},
        data={'model': model},
        timeout=7200,
    )
response.raise_for_status()
payload = response.json()
print((payload.get('text') or '').strip())
PY
