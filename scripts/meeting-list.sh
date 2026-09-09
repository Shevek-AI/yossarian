#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TOKEN="$(tr -d '\r\n' < .runtime-secrets/meeting_api_token)"
PORT="${MEETINGS_HOST_PORT:-}"
if [[ -z "$PORT" && -f .env ]]; then
  value="$(grep '^MEETINGS_HOST_PORT=' .env | tail -1 | cut -d= -f2- || true)"
  [[ -n "$value" ]] && PORT="${value%\"}" && PORT="${PORT#\"}"
fi
PORT="${PORT:-8091}"
payload="$(mktemp)"
trap 'rm -f "$payload"' EXIT
curl -fsS -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/v1/meetings" > "$payload"
python3 - "$payload" <<'PY'
import json, sys
payload=json.load(open(sys.argv[1]))
for job in payload.get('data', []):
    print(f"{job.get('id')}  {str(job.get('status')):10}  {job.get('title')}")
PY
