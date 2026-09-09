from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request

BASE = os.getenv("KEYCLOAK_INTERNAL_URL", "http://keycloak:8080").rstrip("/")
REALM = os.environ["KEYCLOAK_REALM"]
ADMIN_USER = os.environ["KEYCLOAK_ADMIN_USER"]
ADMIN_PASSWORD = os.environ["KEYCLOAK_ADMIN_PASSWORD"]
CLIENT_ID = os.environ["WEB_OIDC_CLIENT_ID"]
CLIENT_SECRET = os.environ["WEB_OIDC_CLIENT_SECRET"]
PUBLIC_URL = os.environ["WEB_PUBLIC_URL"].rstrip("/")
DEV_ADMIN_USERNAME = os.getenv("WEB_DEV_ADMIN_USERNAME", "allowed-user")
ADMIN_ROLE = os.getenv("WEB_OIDC_ADMIN_ROLE", "runtime-admin")


def request(method: str, path: str, *, token: str | None = None, data=None, form=None):
    headers = {}
    body = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if form is not None:
        body = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode(errors="replace")
        raise RuntimeError(f"Keycloak {method} {path}: HTTP {exc.code}: {raw[:1500]}") from exc


_, token_payload = request(
    "POST",
    "/realms/master/protocol/openid-connect/token",
    form={
        "client_id": "admin-cli",
        "grant_type": "password",
        "username": ADMIN_USER,
        "password": ADMIN_PASSWORD,
    },
)
token = token_payload["access_token"]

_, clients = request("GET", f"/admin/realms/{REALM}/clients?clientId={urllib.parse.quote(CLIENT_ID)}", token=token)
payload = {
    "clientId": CLIENT_ID,
    "name": "Runtime Web",
    "enabled": True,
    "protocol": "openid-connect",
    "publicClient": False,
    "secret": CLIENT_SECRET,
    "standardFlowEnabled": True,
    "directAccessGrantsEnabled": False,
    "serviceAccountsEnabled": False,
    "fullScopeAllowed": True,
    "redirectUris": [f"{PUBLIC_URL}/oauth/callback"],
    "webOrigins": [PUBLIC_URL],
    "attributes": {"post.logout.redirect.uris": f"{PUBLIC_URL}/*"},
}
if clients:
    internal_id = clients[0]["id"]
    current = dict(clients[0])
    current.update(payload)
    request("PUT", f"/admin/realms/{REALM}/clients/{internal_id}", token=token, data=current)
    print(f"OIDC client ready: {CLIENT_ID} (updated)")
else:
    request("POST", f"/admin/realms/{REALM}/clients", token=token, data=payload)
    print(f"OIDC client ready: {CLIENT_ID} (created)")

# The default development user doubles as the governance/admin test identity.
_, users = request("GET", f"/admin/realms/{REALM}/users?username={urllib.parse.quote(DEV_ADMIN_USERNAME)}&exact=true", token=token)
_, roles = request("GET", f"/admin/realms/{REALM}/roles", token=token)
admin_role = next((role for role in roles if role.get("name") == ADMIN_ROLE), None)
if users and admin_role:
    user_id = users[0]["id"]
    _, assigned = request("GET", f"/admin/realms/{REALM}/users/{user_id}/role-mappings/realm", token=token)
    if not any(role.get("name") == ADMIN_ROLE for role in assigned):
        request("POST", f"/admin/realms/{REALM}/users/{user_id}/role-mappings/realm", token=token, data=[admin_role])
        print(f"Development admin role granted: {DEV_ADMIN_USERNAME}")
    else:
        print(f"Development admin role ready: {DEV_ADMIN_USERNAME}")
