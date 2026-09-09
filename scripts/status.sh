#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose ps
printf '\nGPU:\n'
nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,utilization.gpu --format=csv || true
printf '\nPrometheus targets:\n'
curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up' 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("{}: {}".format(x["metric"].get("job"), x["value"][1])) for x in d.get("data",{}).get("result",[])]' \
  || echo 'Prometheus not reachable'
printf '\nAudit events:\n'
docker compose exec -T litellm sh -lc 'test -f /var/lib/runtime-audit/audit.jsonl && wc -l < /var/lib/runtime-audit/audit.jsonl || echo 0' 2>/dev/null || true

printf '\nKnowledge:\n'
docker compose exec -T knowledge python3 - <<'PY' 2>/dev/null || true
import json, urllib.request
with urllib.request.urlopen('http://127.0.0.1:8090/health', timeout=2) as r:
    d=json.load(r)
print('documents: {}'.format(d.get('documents')))
print('embedding_model: {}'.format(d.get('embedding_model')))
PY

printf '\nSpeech:\n'
docker compose exec -T speaches python3 - <<'PY' 2>/dev/null || true
import json, os, urllib.request

with urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2) as r:
    d=json.load(r)
print('health: {}'.format(d))
key=os.environ.get('API_KEY', '')
req=urllib.request.Request(
    'http://127.0.0.1:8000/v1/models',
    headers={'Authorization': f'Bearer {key}'} if key else {},
)
with urllib.request.urlopen(req, timeout=2) as r:
    models=json.load(r)
installed={item.get('id') for item in models.get('data', [])}
required=[
    ('stt', os.environ.get('SPEACHES_STT_MODEL')),
    ('diarization-segmentation', os.environ.get('SPEACHES_DIARIZATION_SEGMENTATION_MODEL')),
    ('speaker-embedding', os.environ.get('SPEACHES_DIARIZATION_EMBEDDING_MODEL')),
]
for role, model in required:
    if model:
        print('{}: {} ({})'.format(role, model, 'ready' if model in installed else 'MISSING'))
print('device: cpu/int8')
PY

printf '\nMeetings:\n'
if [[ -f .runtime-secrets/meeting_api_token ]]; then
  token="$(tr -d '\r\n' < .runtime-secrets/meeting_api_token)"
  port="${MEETINGS_HOST_PORT:-8091}"
  if [[ -f .env ]]; then
    value="$(grep '^MEETINGS_HOST_PORT=' .env | tail -1 | cut -d= -f2- || true)"
    [[ -n "$value" ]] && port="${value%\"}" && port="${port#\"}"
  fi
  curl -fsS -H "Authorization: Bearer ${token}" "http://127.0.0.1:${port}/v1/meetings" 2>/dev/null \
    | python3 -c 'import json,sys; jobs=json.load(sys.stdin).get("data",[]); print("jobs: {}".format(len(jobs))); [print("{}: {} ({})".format(j.get("id"), j.get("status"), j.get("title"))) for j in jobs[:5]]' \
    || echo 'Meeting service not reachable'
else
  echo 'Meeting API token missing'
fi

printf '\nWeb:\n'
web_port="${WEB_HOST_PORT:-8080}"
if [[ -f .env ]]; then
  value="$(grep '^WEB_HOST_PORT=' .env | tail -1 | cut -d= -f2- || true)"
  [[ -n "$value" ]] && web_port="${value%\"}" && web_port="${web_port#\"}"
fi
curl -fsS "http://127.0.0.1:${web_port}/health" 2>/dev/null \
  | python3 -m json.tool || echo 'Runtime Web not reachable'


printf '\nPublic web:\n'
docker compose exec -T web-search python3 - <<'PY2' 2>/dev/null || true
import json, urllib.request
with urllib.request.urlopen('http://127.0.0.1:8092/health', timeout=2) as r:
    d=json.load(r)
print('state: {}'.format(d.get('state')))
print('provider: {}'.format(d.get('provider')))
print('configured: {}'.format(d.get('configured')))
print('arbitrary_url_fetch: {}'.format(d.get('arbitrary_url_fetch')))
PY2
