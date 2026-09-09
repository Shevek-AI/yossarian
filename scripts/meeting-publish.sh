#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 2 ]] || { echo "usage: $0 MEETING_ID ACL_CSV" >&2; echo "example ACL: everyone OR user:<oid>,group:<oid>" >&2; exit 2; }
TOKEN="$(tr -d '\r\n' < .runtime-secrets/meeting_api_token)"
PORT="${MEETINGS_HOST_PORT:-}"
if [[ -z "$PORT" && -f .env ]]; then
  value="$(grep '^MEETINGS_HOST_PORT=' .env | tail -1 | cut -d= -f2- || true)"
  [[ -n "$value" ]] && PORT="${value%\"}" && PORT="${PORT#\"}"
fi
PORT="${PORT:-8091}"
PAYLOAD="$(python3 - "$2" <<'PY'
import json, sys
acl=[x.strip() for x in sys.argv[1].split(',') if x.strip()]
print(json.dumps({'acl_principals': acl}))
PY
)"
curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  "http://127.0.0.1:${PORT}/v1/meetings/$1/publish" | python3 -m json.tool
