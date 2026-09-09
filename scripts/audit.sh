#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
count="${1:-20}"
docker compose exec -T litellm python3 - "$count" <<'PY'
from pathlib import Path
import json
import sys

path = Path('/var/lib/runtime-audit/audit.jsonl')
count = int(sys.argv[1])
if not path.exists():
    print('No audit events yet.')
    raise SystemExit(0)
for line in path.read_text().splitlines()[-count:]:
    try:
        print(json.dumps(json.loads(line), indent=2, sort_keys=True))
    except json.JSONDecodeError:
        print(line)
PY
