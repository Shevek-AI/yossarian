#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "Missing .env; run ./scripts/bootstrap.sh" >&2; exit 1; }

python3 - <<'PY'
from pathlib import Path

def env():
    out = {}
    for raw in Path('.env').read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        out[key.strip()] = value
    return out

e = env()
base = e.get('KEYCLOAK_PUBLIC_URL', 'https://auth.localhost:8443')
realm = e.get('KEYCLOAK_REALM', 'local-runtime-dev')
user_role = e.get('LIBRECHAT_OIDC_REQUIRED_ROLE', 'runtime-user')
admin_role = e.get('WEB_OIDC_ADMIN_ROLE', 'runtime-admin')
print(f"Keycloak:       {base}")
print(f"Admin console:  {base}/admin/")
print(f"Realm:          {realm}")
print(f"Admin user:     {e.get('KEYCLOAK_ADMIN_USER', 'admin')}")
print(f"Admin password: {e.get('KEYCLOAK_ADMIN_PASSWORD', '')}")
print()
print("OIDC / retrieval test users:")
pw = e.get('KEYCLOAK_TEST_USER_PASSWORD', '')
print(f"  allowed@example.test   password={pw}  roles={user_role},{admin_role}  docs=public+engineering")
print(f"  finance@example.test   password={pw}  role={user_role}  docs=public+finance")
print(f"  staff@example.test     password={pw}  role={user_role}  docs=public-only")
print(f"  denied@example.test    password={pw}  role=<none>          login=denied")
PY
