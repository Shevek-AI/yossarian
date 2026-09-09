#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

port="${WEB_HOST_PORT:-8080}"
canonical="${WEB_PUBLIC_URL:-http://localhost:${port}}"
if [[ -f .env ]]; then
  value="$(grep '^WEB_HOST_PORT=' .env | tail -1 | cut -d= -f2- || true)"
  [[ -n "$value" ]] && port="${value%\"}" && port="${port#\"}"
  value="$(grep '^WEB_PUBLIC_URL=' .env | tail -1 | cut -d= -f2- || true)"
  if [[ -n "$value" ]]; then
    value="${value%\"}"; value="${value#\"}"
    canonical="$value"
  else
    canonical="http://localhost:${port}"
  fi
fi
loopback="http://127.0.0.1:${port}"

curl -fsS "${loopback}/health" | python3 -m json.tool

# 127.0.0.1 and localhost are different cookie origins. Browser navigation on
# the alternate loopback spelling must be canonicalised before OIDC state is
# minted, otherwise the callback loses the session cookie.
headers="$(mktemp)"
trap 'rm -f "$headers" /tmp/runtime-web-me.json' EXIT
curl -sS -D "$headers" -o /dev/null "${loopback}/login"
grep -qi "^location: ${canonical}/login" "$headers" || {
  echo "alternate loopback login did not canonicalise to ${canonical}" >&2
  cat "$headers" >&2
  exit 1
}

status="$(curl -sS -o /tmp/runtime-web-me.json -w '%{http_code}' "${canonical}/api/me")"
[[ "$status" == "401" ]] || { echo "expected unauthenticated /api/me to return 401, got ${status}" >&2; cat /tmp/runtime-web-me.json >&2; exit 1; }

: > "$headers"
curl -sS -D "$headers" -o /dev/null "${canonical}/login"
grep -qi '^location: https://auth.localhost:8443/' "$headers" || { echo 'canonical web login did not redirect to the configured OIDC issuer' >&2; cat "$headers" >&2; exit 1; }
grep -qi '^set-cookie: runtime_session=' "$headers" || { echo 'canonical login did not set the OIDC state session cookie' >&2; cat "$headers" >&2; exit 1; }

echo "Web smoke: PASS"
echo "Human test: open ${canonical}, sign in as allowed@example.test, then try Meetings / Knowledge / Admin."
