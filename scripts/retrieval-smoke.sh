#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Exercise the retrieval service from inside its private network boundary. The
# host never gets a knowledge-service port just for testing. The first request
# deliberately forges an identity without service auth and must be rejected.
docker compose exec -T knowledge python3 - <<'PY'
import json
import os
import urllib.error
import urllib.request

URL = 'http://127.0.0.1:8090/internal/retrieve'
TOKEN = os.environ['KNOWLEDGE_QUERY_TOKEN']

def request(subject, email, query, *, token=TOKEN):
    body = json.dumps({'query': query, 'limit': 4}).encode()
    headers = {
        'Content-Type': 'application/json',
        'X-Runtime-Subject': subject,
        'X-Runtime-User-Email': email,
    }
    if token is not None:
        headers['Authorization'] = f'Bearer {token}'
    return urllib.request.Request(URL, data=body, method='POST', headers=headers)

def retrieve(subject, email, query):
    with urllib.request.urlopen(request(subject, email, query), timeout=20) as response:
        return json.load(response)

def ids(result):
    return {item['source_document_id'] for item in result['evidence']}

def sources(result):
    return [item['uri'] for item in result['evidence']]

try:
    urllib.request.urlopen(
        request(
            '22222222-2222-4222-8222-222222222222',
            'forged@example.test',
            'What is the FY27 contingency reserve and budget code?',
            token=None,
        ),
        timeout=10,
    )
    raise AssertionError('unauthenticated forged identity unexpectedly reached retrieval')
except urllib.error.HTTPError as exc:
    assert exc.code == 401, exc.code
print('forged identity without query credential: blocked')

engineering = retrieve('11111111-1111-4111-8111-111111111111', 'allowed@example.test', 'What is the Project Kookaburra launch code?')
finance_on_eng = retrieve('22222222-2222-4222-8222-222222222222', 'finance@example.test', 'What is the Project Kookaburra launch code?')
finance = retrieve('22222222-2222-4222-8222-222222222222', 'finance@example.test', 'What is the FY27 contingency reserve and budget code?')
staff_on_finance = retrieve('33333333-3333-4333-8333-333333333333', 'staff@example.test', 'What is the FY27 contingency reserve and budget code?')
staff_public = retrieve('33333333-3333-4333-8333-333333333333', 'staff@example.test', 'When is the coffee machine serviced?')

assert 'engineering-kookaburra' in ids(engineering), engineering
assert 'engineering-kookaburra' not in ids(finance_on_eng), finance_on_eng
assert 'finance-budget' in ids(finance), finance
assert 'finance-budget' not in ids(staff_on_finance), staff_on_finance
assert 'public-handbook' in ids(staff_public), staff_public

print('engineering user:', sources(engineering))
print('finance asking engineering:', sources(finance_on_eng))
print('finance user:', sources(finance))
print('staff asking finance:', sources(staff_on_finance))
print('staff public:', sources(staff_public))
print('Authenticated ACL retrieval smoke: PASS')
PY
