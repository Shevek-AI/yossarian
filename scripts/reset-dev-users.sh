#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Development-only helper for resetting synthetic OIDC fixture accounts in
# LibreChat after identity changes. MongoDB is authenticated in the current
# reference implementation, so use the least-privilege application credential.
docker compose exec -T mongodb bash -ec '
mongosh --quiet --norc \
  "mongodb://${MONGODB_APP_USERNAME}:${MONGODB_APP_PASSWORD}@127.0.0.1:27017/LibreChat?authSource=LibreChat" \
  --eval '\''
db.users.deleteMany({email: {$in: [
  "allowed@example.test",
  "finance@example.test",
  "staff@example.test",
  "denied@example.test"
]}})
'\''
'
