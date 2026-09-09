#!/usr/bin/env bash
set -euo pipefail

: "${MONGODB_APP_USERNAME:?MONGODB_APP_USERNAME is required}"
: "${MONGODB_APP_PASSWORD:?MONGODB_APP_PASSWORD is required}"

DB_PATH=/data/db
BOOTSTRAP_PORT=27018
BOOTSTRAP_LOG=/tmp/mongodb-auth-bootstrap.log

# Match the official image's privilege drop even though this wrapper replaces
# its normal entrypoint. Avoid leaving persistent database files owned by root.
if [[ "$(id -u)" == "0" ]]; then
  find -L "$DB_PATH" \! -user mongodb -exec chown mongodb '{}' +
  exec gosu mongodb /bin/bash "$0" "$@"
fi

cleanup() {
  mongod --dbpath "$DB_PATH" --shutdown >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Existing development volumes predate Mongo authentication. Bootstrap on a
# loopback-only port so there is never an unauthenticated network listener,
# create/update the least-privilege LibreChat user, then restart with --auth.
mongod \
  --dbpath "$DB_PATH" \
  --bind_ip 127.0.0.1 \
  --port "$BOOTSTRAP_PORT" \
  --noauth \
  --fork \
  --logpath "$BOOTSTRAP_LOG"

for _ in $(seq 1 60); do
  if mongosh --quiet --norc "mongodb://127.0.0.1:${BOOTSTRAP_PORT}/LibreChat" \
      --eval "db.adminCommand('ping').ok" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

mongosh --quiet --norc "mongodb://127.0.0.1:${BOOTSTRAP_PORT}/LibreChat" --eval '
const appDb = db.getSiblingDB("LibreChat");
const username = process.env.MONGODB_APP_USERNAME;
const password = process.env.MONGODB_APP_PASSWORD;
const roles = [{role: "readWrite", db: "LibreChat"}];
if (appDb.getUser(username)) {
  appDb.updateUser(username, {pwd: password, roles});
} else {
  appDb.createUser({user: username, pwd: password, roles});
}
' >/dev/null

mongod --dbpath "$DB_PATH" --shutdown >/dev/null
trap - EXIT

exec mongod \
  --dbpath "$DB_PATH" \
  --bind_ip_all \
  --port 27017 \
  --auth
