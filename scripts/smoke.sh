#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "Missing .env; run ./scripts/bootstrap.sh" >&2; exit 1; }

# .env is Docker Compose configuration, not a shell script. Read only the
# values needed here without sourcing it.
env_get() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

name = sys.argv[1]
for raw in Path('.env').read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    key, value = line.split('=', 1)
    if key.strip() != name:
        continue
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        value = value[1:-1]
    print(value)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

LITELLM_HOST_PORT="$(env_get LITELLM_HOST_PORT 2>/dev/null || echo 4000)"
LIBRECHAT_HOST_PORT="$(env_get LIBRECHAT_HOST_PORT 2>/dev/null || echo 3080)"
LIBRECHAT_PUBLIC_URL="$(env_get LIBRECHAT_PUBLIC_URL 2>/dev/null || true)"
LITELLM_MASTER_KEY="$(env_get LITELLM_MASTER_KEY)"
KEYCLOAK_PUBLIC_URL="$(env_get KEYCLOAK_PUBLIC_URL)"
KEYCLOAK_REALM="$(env_get KEYCLOAK_REALM)"
PROMETHEUS_HOST_PORT="$(env_get PROMETHEUS_HOST_PORT 2>/dev/null || echo 9090)"
MEETINGS_HOST_PORT="$(env_get MEETINGS_HOST_PORT 2>/dev/null || echo 8091)"
WEB_HOST_PORT="$(env_get WEB_HOST_PORT 2>/dev/null || echo 8080)"

API_BASE="http://127.0.0.1:${LITELLM_HOST_PORT}"
UI_BASE="${LIBRECHAT_PUBLIC_URL:-http://localhost:${LIBRECHAT_HOST_PORT}}"
OIDC_DISCOVERY="${KEYCLOAK_PUBLIC_URL}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration"

wait_http() {
  local name="$1"
  local url="$2"
  local auth_header="${3:-}"
  printf 'Waiting for %s at %s ' "$name" "$url"
  for _ in $(seq 1 120); do
    if [[ -n "$auth_header" ]]; then
      if curl -fsS -H "$auth_header" "$url" >/dev/null 2>&1; then echo "ready"; return 0; fi
    else
      if curl -fsS "$url" >/dev/null 2>&1; then echo "ready"; return 0; fi
    fi
    printf '.'
    sleep 2
  done
  echo
  echo "$name did not become ready" >&2
  return 1
}

wait_http "LiteLLM" "${API_BASE}/health/liveliness"
wait_http "LibreChat" "${UI_BASE}/api/config"
wait_http "Prometheus" "http://127.0.0.1:${PROMETHEUS_HOST_PORT}/-/ready"
wait_http "Meetings" "http://127.0.0.1:${MEETINGS_HOST_PORT}/health"
wait_http "Runtime Web" "http://127.0.0.1:${WEB_HOST_PORT}/health"

# Use Caddy's mounted development root directly rather than requiring the host
# trust store for the automated smoke check.
CA_TMP="$(mktemp --suffix=.crt)"
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt "$CA_TMP" >/dev/null
printf 'Waiting for Keycloak discovery at %s ' "$OIDC_DISCOVERY"
for _ in $(seq 1 60); do
  if curl --cacert "$CA_TMP" -fsS "$OIDC_DISCOVERY" >/dev/null 2>&1; then echo "ready"; break; fi
  printf '.'
  sleep 2
done

printf '\n--- models ---\n'
curl -fsS \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  "${API_BASE}/v1/models" | python3 -m json.tool

printf '\n--- chat completion ---\n'
CHAT_TMP="$(mktemp --suffix=.json)"
trap 'rm -f "$CA_TMP" "$CHAT_TMP"' EXIT
curl -fsS \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  -H 'X-Runtime-User-ID: smoke-test' \
  -H 'X-Runtime-User-Email: smoke@example.test' \
  -H 'X-Runtime-Client: smoke' \
  -H 'X-Runtime-Conversation-ID: smoke-conversation' \
  -H 'X-Runtime-Message-ID: smoke-message' \
  "${API_BASE}/v1/chat/completions" \
  -d '{"model":"general","messages":[{"role":"user","content":"Reply with exactly: local runtime online"}],"temperature":0,"max_tokens":512,"chat_template_kwargs":{"enable_thinking":false}}' \
  > "$CHAT_TMP"
python3 -m json.tool "$CHAT_TMP"
python3 - "$CHAT_TMP" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
text = ((payload.get('choices') or [{}])[0].get('message') or {}).get('content') or ''
assert 'local runtime online' in text.lower(), payload
PY

printf '\n--- prometheus targets ---\n'
curl -fsS "http://127.0.0.1:${PROMETHEUS_HOST_PORT}/api/v1/query?query=up" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for row in data.get("data", {}).get("result", []):
    print("{}: {}".format(row["metric"].get("job"), row["value"][1]))
'

printf '\n--- latest audit event ---\n'
audit_ready=0
for _ in $(seq 1 20); do
  if docker compose exec -T litellm python3 - <<'PY' >/dev/null 2>&1
from pathlib import Path
import json

path = Path('/var/lib/runtime-audit/audit.jsonl')
if not path.exists() or not path.read_text().strip():
    raise SystemExit(1)
event = json.loads(path.read_text().splitlines()[-1])
raise SystemExit(0 if event.get('principal', {}).get('id') == 'smoke-test' else 1)
PY
  then
    audit_ready=1
    break
  fi
  sleep 1
done
if [[ "$audit_ready" != 1 ]]; then
  echo 'Audit callback did not write the smoke-test event' >&2
  exit 1
fi
docker compose exec -T litellm python3 - <<'PY'
from pathlib import Path
import json

event = json.loads(Path('/var/lib/runtime-audit/audit.jsonl').read_text().splitlines()[-1])
print(json.dumps(event, indent=2, sort_keys=True))
assert event.get('content_logged') is False
assert event.get('principal', {}).get('id') == 'smoke-test'
assert event.get('status') == 'success'
assert 'messages' not in event
assert 'response' not in event
PY

printf '\nHuman audit test after OIDC login:\n'
printf '  Send one UI message, then run `make audit`; the event should show your authenticated LibreChat user and no prompt/response body.\n'

printf '\nHuman OIDC test:\n'
printf '  1. Open %s and sign out of any local account.\n' "$UI_BASE"
printf '  2. Click "Sign in with SSO".\n'
printf '  3. Run `make identity-info` for the development test users.\n'
printf '  4. allowed@example.test should succeed; denied@example.test should be rejected.\n'

printf '\n--- runtime web ---\n'
./scripts/web-smoke.sh

printf '\n--- explicit document ingress ---\n'
./scripts/ingest.sh

printf '\n--- permission-aware retrieval ---\n'
./scripts/retrieval-smoke.sh

printf '\n--- ingress lifecycle ---\n'
./scripts/ingress-lifecycle-smoke.sh

printf '\n--- local transcription ---\n'
./scripts/transcription-smoke.sh

printf '\n--- meeting workflow ---\n'
./scripts/meeting-smoke.sh
