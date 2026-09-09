#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 1 ]] || { echo "usage: $0 MEETING_ID" >&2; exit 2; }
TOKEN="$(tr -d '\r\n' < .runtime-secrets/meeting_api_token)"
PORT="${MEETINGS_HOST_PORT:-}"
if [[ -z "$PORT" && -f .env ]]; then
  value="$(grep '^MEETINGS_HOST_PORT=' .env | tail -1 | cut -d= -f2- || true)"
  [[ -n "$value" ]] && PORT="${value%\"}" && PORT="${PORT#\"}"
fi
PORT="${PORT:-8091}"
curl -fsS -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/v1/meetings/$1" | python3 -m json.tool
