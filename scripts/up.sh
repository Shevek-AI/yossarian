#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bootstrap.sh

# Bind-mount sources must exist as regular files before Docker starts. If a
# source path is missing Docker can create a directory there, which produces a
# confusing EISDIR error inside the service.
for config_file in \
  config/litellm.yaml \
  config/librechat.yaml \
  config/litellm_callbacks.py \
  config/prometheus.yaml \
  config/Caddyfile \
  config/keycloak/yossarian-dev-realm.json \
  services/mongodb/entrypoint.sh; do
  if [[ ! -f "$config_file" ]]; then
    echo "Expected regular config file: $config_file" >&2
    if [[ -d "$config_file" ]]; then
      echo "It is currently a directory. Remove it and restore the tracked file before starting." >&2
    fi
    exit 1
  fi
done

docker compose pull --ignore-buildable
docker compose up -d --build

# Fresh realms import the web OIDC client. Existing persistent dev realms do not
# re-import realm JSON, so upgrade them idempotently through the admin API.
docker compose --profile tools build oidc-provision
docker compose --profile tools run --rm oidc-provision

# A fresh Speaches cache returns 404 for transcription until the configured
# model is installed. Make startup own that requirement.
./scripts/ensure-speech-models.sh

echo
echo "Started. vLLM first boot can take several minutes while it downloads/loads/warms the model."
echo "Identity: Keycloak -> Caddy local TLS -> LibreChat OIDC."
echo "Watch with: docker compose logs -f web web-search keycloak caddy librechat knowledge postgres speaches meetings litellm vllm prometheus dcgm-exporter"
echo "Then run:   ./scripts/smoke.sh"
echo "Web:        http://localhost:${WEB_HOST_PORT:-8080}"
echo "Public web: controlled MCP egress; disabled unless WEB_SEARCH_ENABLED=1"
echo "Metrics:    http://localhost:${PROMETHEUS_HOST_PORT:-9090}"
echo "Audit:      make audit"
echo "Ingress:    make ingest"
echo "Meeting:    make meeting AUDIO=/path/to/meeting.m4a (async service; CLI waits by default)"
echo "Meetings:   make meeting-list"
echo "Retrieval:  make retrieval-smoke"
echo "Security:   make security-smoke"
echo "OIDC creds: make identity-info"
echo "Browser CA: ./scripts/trust-dev-ca.sh (once, if your browser does not trust auth.localhost)"
