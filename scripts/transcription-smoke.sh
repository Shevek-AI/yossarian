#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/ensure-speech-models.sh

printf 'Local transcription fixture: '
docker compose exec -T speaches python3 - <<'PY'
import os
from pathlib import Path

import httpx

path = Path('/fixtures/audio/transcription_smoke.wav')
assert path.is_file(), path
model = os.environ['SPEACHES_STT_MODEL']
key = os.environ['API_KEY']
with path.open('rb') as f:
    response = httpx.post(
        'http://127.0.0.1:8000/v1/audio/transcriptions',
        headers={'Authorization': f'Bearer {key}'},
        files={'file': (path.name, f, 'audio/wav')},
        data={'model': model},
        timeout=900,
    )
response.raise_for_status()
payload = response.json()
text = (payload.get('text') or '').strip()
normalized = text.lower()
for expected in ('local', 'runtime', 'meeting'):
    assert expected in normalized, (expected, payload)
print(text)
print(f'Transcription model: {model}')
print('Transcription smoke: PASS')
PY
