#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example."
fi

python3 - <<'PY'
from pathlib import Path
import os
import secrets

p = Path('.env')
lines = p.read_text().splitlines()
spec = {
    'VLLM_API_KEY': lambda: 'sk-' + secrets.token_urlsafe(32),
    'LITELLM_MASTER_KEY': lambda: 'sk-' + secrets.token_urlsafe(32),
    'LIBRECHAT_CREDS_KEY': lambda: secrets.token_hex(32),
    'LIBRECHAT_CREDS_IV': lambda: secrets.token_hex(16),
    'LIBRECHAT_JWT_SECRET': lambda: secrets.token_hex(32),
    'LIBRECHAT_JWT_REFRESH_SECRET': lambda: secrets.token_hex(32),
    'LIBRECHAT_OIDC_CLIENT_SECRET': lambda: secrets.token_urlsafe(40),
    'LIBRECHAT_OIDC_SESSION_SECRET': lambda: secrets.token_hex(32),
    'KEYCLOAK_ADMIN_PASSWORD': lambda: secrets.token_urlsafe(24),
    'KEYCLOAK_TEST_USER_PASSWORD': lambda: secrets.token_urlsafe(18),
    'POSTGRES_PASSWORD': lambda: secrets.token_hex(24),
    'SPEACHES_API_KEY': lambda: 'sk-' + secrets.token_urlsafe(32),
    'WEB_OIDC_CLIENT_SECRET': lambda: secrets.token_urlsafe(40),
    'WEB_SESSION_SECRET': lambda: secrets.token_hex(32),
    'KNOWLEDGE_QUERY_TOKEN': lambda: secrets.token_urlsafe(32),
    'MONGODB_APP_PASSWORD': lambda: secrets.token_urlsafe(32),
}

seen = set()
out = []
for line in lines:
    for name, make in spec.items():
        prefix = name + '='
        if line.startswith(prefix):
            seen.add(name)
            value = line[len(prefix):]
            if not value or value == 'CHANGE_ME':
                line = prefix + make()
            break
    out.append(line)

for name, make in spec.items():
    if name not in seen:
        out.append(f'{name}={make()}')

# Fill missing settings without overwriting existing development choices.
def ensure(name: str, value: str):
    prefix = name + '='
    if not any(line.startswith(prefix) for line in out):
        out.append(prefix + value)

def upsert(name: str, value: str):
    prefix = name + '='
    for i, line in enumerate(out):
        if line.startswith(prefix):
            out[i] = prefix + value
            return
    out.append(prefix + value)

ensure('VLLM_REASONING_PARSER', 'qwen3')
ensure('LIBRECHAT_HOST_PORT', '3080')
ensure('LIBRECHAT_PUBLIC_URL', 'http://localhost:3080')
ensure('LIBRECHAT_APP_TITLE', '"Yossarian"')
ensure('LIBRECHAT_IMAGE', 'ghcr.io/danny-avila/librechat:v0.8.7')
ensure('MONGODB_IMAGE', 'mongo:8.0.20')
ensure('MONGODB_APP_USERNAME', 'librechat')
ensure('KEYCLOAK_REALM', 'yossarian-dev')
ensure('KEYCLOAK_ADMIN_USER', 'admin')
ensure('KEYCLOAK_TLS_HOST_PORT', '8443')
ensure('KEYCLOAK_PUBLIC_URL', 'https://auth.localhost:8443')
ensure('LIBRECHAT_OIDC_CLIENT_ID', 'librechat')
ensure('LIBRECHAT_OIDC_REQUIRED_ROLE', 'runtime-user')
ensure('KEYCLOAK_IMAGE', 'quay.io/keycloak/keycloak:26.7.3')
ensure('CADDY_IMAGE', 'caddy:2.11.4')
ensure('RUNTIME_VERSION', '0.1.0')
ensure('PROMETHEUS_HOST_PORT', '9090')
ensure('PROMETHEUS_RETENTION', '7d')
ensure('PROMETHEUS_IMAGE', 'prom/prometheus:v3.14.0')
ensure('DCGM_EXPORTER_IMAGE', 'nvcr.io/nvidia/k8s/dcgm-exporter:4.6.0-4.8.3-distroless')
ensure('POSTGRES_IMAGE', 'pgvector/pgvector:0.8.6-pg18-bookworm')
ensure('POSTGRES_DB', 'runtime')
ensure('POSTGRES_USER', 'runtime')
ensure('SPEACHES_IMAGE', 'ghcr.io/speaches-ai/speaches:0.9.0-rc.3-cpu@sha256:2163775b6df5e451a71200e8f675fed68dbd8ab184fc604453d549e486f22fd2')
ensure('SPEACHES_STT_MODEL', 'Systran/faster-distil-whisper-small.en')
ensure('SPEACHES_STT_MODEL_TTL', '-1')
ensure('SPEACHES_ENABLE_DIARIZATION', '1')
ensure('SPEACHES_DIARIZATION_SEGMENTATION_MODEL', 'fedirz/segmentation_community_1')
ensure('SPEACHES_DIARIZATION_EMBEDDING_MODEL', 'Wespeaker/wespeaker-voxceleb-resnet34-LM')
ensure('SPEACHES_EXTRA_MODELS', '')
ensure('MEETING_SUMMARY_MODEL', 'general')
ensure('MEETING_NORMALIZE_MODEL', 'general')
ensure('MEETINGS_HOST_PORT', '8091')
ensure('WEB_HOST_PORT', '8080')
ensure('WEB_PUBLIC_URL', 'http://localhost:8080')
ensure('WEB_OIDC_CLIENT_ID', 'runtime-web')
ensure('WEB_OIDC_REQUIRED_ROLE', 'runtime-user')
ensure('WEB_OIDC_ADMIN_ROLE', 'runtime-admin')
ensure('WEB_COOKIE_SECURE', '0')
ensure('WEB_SEARCH_ENABLED', '0')
ensure('WEB_SEARCH_PROVIDER', 'brave')
ensure('BRAVE_SEARCH_API_KEY', '')
ensure('WEB_SEARCH_COUNTRY', 'AU')
ensure('WEB_SEARCH_LANGUAGE', 'en')
ensure('WEB_SEARCH_MAX_RESULTS', '6')
ensure('WEB_SEARCH_TIMEOUT_SECONDS', '15')
ensure('WEB_SEARCH_MAX_REQUESTS_PER_MINUTE', '10')
ensure('WEB_SEARCH_MAX_REQUESTS_PER_HOUR', '50')
ensure('WEB_SEARCH_MAX_REQUESTS_PER_DAY', '100')
ensure('MEETING_MAX_UPLOAD_BYTES', '2147483648')
ensure('KNOWLEDGE_EMBED_MODEL', 'BAAI/bge-small-en-v1.5')
ensure('LOGIN_MAX', '50')
ensure('LOGIN_WINDOW', '1')

# The LiteLLM metrics credential is host-group-readable (not world-readable) so
# the non-root Prometheus process can read the bind-mounted secret. Keep the
# supplemental group in sync when a checkout moves between hosts.
upsert('PROMETHEUS_SECRET_GID', str(os.getgid()))

# Public release metadata is authoritative; bootstrap may be rerun on an
# existing development checkout without regenerating its credentials.
upsert('LIBRECHAT_APP_TITLE', '"Yossarian"')
upsert('RUNTIME_VERSION', '0.1.0')

p.write_text('\n'.join(out) + '\n')
PY

# Render the Keycloak import as a dedicated directory mounted over
# /opt/keycloak/data/import. This keeps import files out of the persistent
# Keycloak data volume, so realm/file renames cannot leave stale zero-byte
# mount-point artifacts that Keycloak later tries to parse.
python3 - <<'PY'
from pathlib import Path

def get_env(name: str) -> str:
    for raw in Path('.env').read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        if key.strip() == name:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            return value
    raise SystemExit(f'missing {name} in .env')

realm = get_env('KEYCLOAK_REALM')
if not realm or '/' in realm or '\\' in realm:
    raise SystemExit('KEYCLOAK_REALM must be a simple realm name')
src = Path('config/keycloak/yossarian-dev-realm.json')
out_dir = Path('.runtime-keycloak-import')
out_dir.mkdir(mode=0o755, exist_ok=True)
out_dir.chmod(0o755)
for old in out_dir.iterdir():
    if old.is_file() or old.is_symlink():
        old.unlink()
dst = out_dir / f'{realm}-realm.json'
dst.write_bytes(src.read_bytes())
dst.chmod(0o644)
PY

# Prometheus needs the LiteLLM bearer token for its private /metrics scrape.
# Keep the rendered secret out of git and expose only the file into Prometheus.
mkdir -p .runtime-secrets
chmod 0700 .runtime-secrets
python3 - <<'PY'
from pathlib import Path
import secrets

for name in ('knowledge_ingest_token', 'meeting_api_token'):
    p = Path('.runtime-secrets') / name
    if not p.exists() or not p.read_text().strip():
        p.write_text(secrets.token_urlsafe(32) + '\n')
    p.chmod(0o600)
PY
python3 - <<'PY'
from pathlib import Path

def get_env(name: str) -> str:
    for raw in Path('.env').read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        if key.strip() == name:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            return value
    raise SystemExit(f'missing {name} in .env')

p = Path('.runtime-secrets/litellm_master_key')
p.write_text(get_env('LITELLM_MASTER_KEY') + '\n')
p.chmod(0o640)
PY

mkdir -p "$HOME/.cache/huggingface" artifacts/meetings
echo "Local runtime secrets/config are present."
echo "Model: $(grep '^VLLM_MODEL=' .env | cut -d= -f2-)"
echo "Web:   $(grep '^WEB_PUBLIC_URL=' .env | cut -d= -f2-)"
echo "Chat:  $(grep '^LIBRECHAT_PUBLIC_URL=' .env | cut -d= -f2-)"
echo "OIDC:  $(grep '^KEYCLOAK_PUBLIC_URL=' .env | cut -d= -f2-)"
echo "Metrics: http://localhost:$(grep '^PROMETHEUS_HOST_PORT=' .env | cut -d= -f2-)"
echo "Knowledge: explicit ingress + permission-aware RAG enabled (internal-only)"
echo "Speech: local Speaches/faster-whisper STT enabled (CPU, internal-only)"
echo "Meetings: async draft/review/publish service on http://localhost:$(grep '^MEETINGS_HOST_PORT=' .env | cut -d= -f2-)"
echo "Public web: controlled MCP search egress (disabled unless WEB_SEARCH_ENABLED=1)"
