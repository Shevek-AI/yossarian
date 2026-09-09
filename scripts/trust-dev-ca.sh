#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

container="$(docker compose ps -q caddy)"
[[ -n "$container" ]] || { echo "Caddy is not running; start the runtime first." >&2; exit 1; }

while ! docker compose exec -T caddy test -s /data/caddy/pki/authorities/local/root.crt 2>/dev/null; do
  echo "Waiting for Caddy development CA..."
  sleep 1
done

tmp="$(mktemp --suffix=.crt)"
trap 'rm -f "$tmp"' EXIT

docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt "$tmp" >/dev/null

echo "Installing the local development CA into the Ubuntu system trust store."
echo "This is for localhost development only; production will use normal deployment TLS."
sudo install -m 0644 "$tmp" /usr/local/share/ca-certificates/yossarian-dev.crt
sudo update-ca-certificates

echo
echo "Installed. Restart the browser if it was already open."
echo "If Firefox still warns, import /usr/local/share/ca-certificates/yossarian-dev.crt into Firefox Authorities once."
