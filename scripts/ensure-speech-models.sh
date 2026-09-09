#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

printf 'Waiting for Speaches '
ready=0
for _ in $(seq 1 120); do
  if docker compose exec -T speaches python3 - <<'PY' >/dev/null 2>&1
import urllib.request
urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).read()
PY
  then
    echo ready
    ready=1
    break
  fi
  printf '.'
  sleep 2
done
if [[ "$ready" != 1 ]]; then
  echo
  echo 'Speaches did not become ready' >&2
  exit 1
fi

# Speaches 0.9 treats model installation as explicit provisioning. A healthy
# service can still return 404 for a capability whose backing model is absent,
# so startup verifies every model required by the enabled speech capabilities.
docker compose exec -T speaches python3 - <<'PY'
import os
import httpx


def enabled(name: str, default: str = '1') -> bool:
    return os.getenv(name, default).strip().lower() not in {'0', 'false', 'no', 'off'}

required: list[tuple[str, str]] = []
stt = os.getenv('SPEACHES_STT_MODEL', '').strip()
if stt:
    required.append(('stt', stt))

if enabled('SPEACHES_ENABLE_DIARIZATION'):
    segmentation = os.getenv('SPEACHES_DIARIZATION_SEGMENTATION_MODEL', '').strip()
    embedding = os.getenv('SPEACHES_DIARIZATION_EMBEDDING_MODEL', '').strip()
    if segmentation:
        required.append(('diarization-segmentation', segmentation))
    if embedding:
        required.append(('speaker-embedding', embedding))

for model in os.getenv('SPEACHES_EXTRA_MODELS', '').split(','):
    model = model.strip()
    if model:
        required.append(('extra', model))

# Preserve declaration order while avoiding duplicate downloads.
seen = set()
deduped = []
for role, model in required:
    if model in seen:
        continue
    seen.add(model)
    deduped.append((role, model))
required = deduped
if not required:
    raise SystemExit('No speech models configured')

key = os.environ['API_KEY']
headers = {'Authorization': f'Bearer {key}'}
with httpx.Client(timeout=1800) as client:
    models = client.get('http://127.0.0.1:8000/v1/models', headers=headers)
    models.raise_for_status()
    installed = {item.get('id') for item in models.json().get('data', [])}

    for role, model in required:
        if model not in installed:
            print(f'Downloading speech model [{role}]: {model}', flush=True)
            response = client.post(f'http://127.0.0.1:8000/v1/models/{model}', headers=headers)
            response.raise_for_status()
            installed.add(model)
        print(f'Speech model ready [{role}]: {model}')
PY
