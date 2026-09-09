#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Exercise the governed ingestion API directly from inside the private knowledge
# service. The ordinary `make ingest` smoke separately proves the connector ->
# API boundary; this test focuses on update, ACL-only change and deletion.
docker compose exec -T knowledge python3 - <<'PY'
import json
import os
import urllib.request
from pathlib import Path

BASE = 'http://127.0.0.1:8090'
SOURCE = 'smoke-lifecycle'
DOC = 'lifecycle-canary'
ALLOWED = '11111111-1111-4111-8111-111111111111'
STAFF = '33333333-3333-4333-8333-333333333333'
TOKEN = Path('/run/secrets/knowledge_ingest_token').read_text().strip()
QUERY_TOKEN = os.environ['KNOWLEDGE_QUERY_TOKEN']


def post(path, payload, headers=None):
    body = json.dumps(payload).encode()
    request_headers = {'Content-Type': 'application/json'}
    if headers:
        request_headers.update(headers)
    req = urllib.request.Request(BASE + path, data=body, method='POST', headers=request_headers)
    with urllib.request.urlopen(req, timeout=120) as response:
        return json.load(response)


def sync(documents):
    return post(
        f'/internal/sources/{SOURCE}/sync',
        {'source_type': 'smoke', 'full_snapshot': True, 'documents': documents},
        {'Authorization': f'Bearer {TOKEN}'},
    )


def doc(content, principals):
    return {
        'source_document_id': DOC,
        'version': content,
        'uri': f'smoke://{SOURCE}/{DOC}',
        'title': 'Ingress lifecycle canary',
        'mime_type': 'text/plain',
        'content': content,
        'acl_principals': principals,
    }


def retrieve(subject, query):
    result = post(
        '/internal/retrieve',
        {'query': query, 'limit': 10},
        {'Authorization': f'Bearer {QUERY_TOKEN}', 'X-Runtime-Subject': subject},
    )
    return {item['source_document_id'] for item in result['evidence']}


try:
    # Make the test repeatable even after an interrupted previous run.
    sync([])

    first = sync([doc('ORANGE-LANTERN-417 belongs to the engineering canary.', [f'user:{ALLOWED}'])])
    assert first['inserted'] == 1 and first['chunks_written'] >= 1, first

    same = sync([doc('ORANGE-LANTERN-417 belongs to the engineering canary.', [f'user:{ALLOWED}'])])
    assert same['unchanged'] == 1 and same['chunks_written'] == 0, same

    acl = sync([doc('ORANGE-LANTERN-417 belongs to the engineering canary.', [f'user:{STAFF}'])])
    assert acl['updated'] == 1 and acl['chunks_written'] == 0, acl
    assert DOC not in retrieve(ALLOWED, 'ORANGE-LANTERN-417'), 'revoked user still retrieved canary'
    assert DOC in retrieve(STAFF, 'ORANGE-LANTERN-417'), 'newly authorised user cannot retrieve canary'

    changed = sync([doc('PURPLE-LANTERN-992 belongs to the staff canary.', [f'user:{STAFF}'])])
    assert changed['updated'] == 1 and changed['chunks_written'] >= 1, changed
    assert DOC in retrieve(STAFF, 'PURPLE-LANTERN-992'), 'updated content was not retrievable'

    deleted = sync([])
    assert deleted['deleted'] == 1, deleted
    assert DOC not in retrieve(STAFF, 'PURPLE-LANTERN-992'), 'deleted document remained retrievable'

    print('insert:', first)
    print('idempotent:', same)
    print('ACL-only update:', acl)
    print('content update:', changed)
    print('delete:', deleted)
    print('Ingress lifecycle smoke: PASS')
finally:
    # Best-effort cleanup keeps the test source from polluting later retrievals.
    try:
        sync([])
    except Exception:
        pass
PY
