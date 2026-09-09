from __future__ import annotations

import json
import os
import secrets
from pathlib import Path
from typing import Any
from urllib.parse import urlencode, urlsplit

import httpx
import jwt
from fastapi import Body, FastAPI, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from jwt import PyJWK
from starlette.middleware.sessions import SessionMiddleware

MEETINGS_URL = os.getenv("MEETINGS_URL", "http://meetings:8091").rstrip("/")
KNOWLEDGE_URL = os.getenv("KNOWLEDGE_URL", "http://knowledge:8090").rstrip("/")
LITELLM_URL = os.getenv("LITELLM_URL", "http://litellm:4000").rstrip("/")
SPEACHES_URL = os.getenv("SPEACHES_URL", "http://speaches:8000").rstrip("/")
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus:9090").rstrip("/")
LIBRECHAT_INTERNAL_URL = os.getenv("LIBRECHAT_INTERNAL_URL", "http://librechat:3080").rstrip("/")
LIBRECHAT_PUBLIC_URL = os.getenv("LIBRECHAT_PUBLIC_URL", "http://localhost:3080").rstrip("/")
WEB_SEARCH_URL = os.getenv("WEB_SEARCH_URL", "http://web-search:8092").rstrip("/")

OIDC_ISSUER = os.environ["WEB_OIDC_ISSUER"].rstrip("/")
OIDC_CLIENT_ID = os.environ["WEB_OIDC_CLIENT_ID"]
OIDC_CLIENT_SECRET = os.environ["WEB_OIDC_CLIENT_SECRET"]
WEB_PUBLIC_URL = os.getenv("WEB_PUBLIC_URL", "http://localhost:8080").rstrip("/")
WEB_REQUIRED_ROLE = os.getenv("WEB_OIDC_REQUIRED_ROLE", "runtime-user")
WEB_ADMIN_ROLE = os.getenv("WEB_OIDC_ADMIN_ROLE", "runtime-admin")
WEB_SESSION_SECRET = os.environ["WEB_SESSION_SECRET"]
WEB_COOKIE_SECURE = os.getenv("WEB_COOKIE_SECURE", "0").lower() in {"1", "true", "yes", "on"}
CA_CERT = os.getenv("WEB_OIDC_CA_CERT", "/certs/root.crt")

MEETING_TOKEN_FILE = Path(os.getenv("MEETING_API_TOKEN_FILE", "/run/secrets/meeting_api_token"))
KNOWLEDGE_QUERY_TOKEN = os.environ["KNOWLEDGE_QUERY_TOKEN"]
AUDIT_LOG_PATH = Path(os.getenv("RUNTIME_AUDIT_LOG_PATH", "/var/lib/runtime-audit/audit.jsonl"))
STATIC_DIR = Path(__file__).parent / "static"

meeting_token = ""
oidc_metadata: dict[str, Any] = {}
ojwks: dict[str, Any] = {}

app = FastAPI(title="Runtime Web", version="0.1")
app.add_middleware(
    SessionMiddleware,
    secret_key=WEB_SESSION_SECRET,
    same_site="lax",
    https_only=WEB_COOKIE_SECURE,
    session_cookie="runtime_session",
    max_age=60 * 60 * 12,
)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


def _verify() -> str | bool:
    return CA_CERT if Path(CA_CERT).is_file() else True


def _canonical_redirect(request: Request) -> RedirectResponse | None:
    """Keep browser navigation on WEB_PUBLIC_URL before creating OIDC/session state.

    In development, 127.0.0.1 and localhost reach the same socket but are
    different cookie origins. Starting OIDC on one and returning to the other
    loses the state cookie. Redirect navigation to the configured canonical
    origin before any OAuth state is created.
    """
    expected = urlsplit(WEB_PUBLIC_URL)
    current_port = request.url.port
    expected_port = expected.port
    current_origin = (request.url.scheme, request.url.hostname, current_port)
    expected_origin = (expected.scheme, expected.hostname, expected_port)
    if current_origin == expected_origin:
        return None
    target = f"{WEB_PUBLIC_URL}{request.url.path}"
    if request.url.query:
        target += f"?{request.url.query}"
    return RedirectResponse(target, status_code=307)


async def _load_oidc() -> None:
    global oidc_metadata, jwks
    async with httpx.AsyncClient(verify=_verify(), timeout=15) as client:
        metadata_response = await client.get(f"{OIDC_ISSUER}/.well-known/openid-configuration")
        metadata_response.raise_for_status()
        metadata = metadata_response.json()
        jwks_response = await client.get(metadata["jwks_uri"])
        jwks_response.raise_for_status()
    oidc_metadata = metadata
    jwks = jwks_response.json()


@app.on_event("startup")
async def startup() -> None:
    global meeting_token
    meeting_token = MEETING_TOKEN_FILE.read_text().strip()
    if not meeting_token or not KNOWLEDGE_QUERY_TOKEN:
        raise RuntimeError("internal API credential is missing")
    await _load_oidc()


def _user(request: Request) -> dict[str, Any]:
    user = request.session.get("user")
    if not isinstance(user, dict) or not user.get("sub"):
        raise HTTPException(status_code=401, detail="sign in required")
    return user


def _is_admin(user: dict[str, Any]) -> bool:
    return WEB_ADMIN_ROLE in set(user.get("roles") or [])


def _csrf(request: Request, supplied: str | None) -> None:
    expected = request.session.get("csrf")
    if not expected or not supplied or not secrets.compare_digest(str(expected), supplied):
        raise HTTPException(status_code=403, detail="invalid CSRF token")


def _meeting_allowed(job: dict[str, Any], user: dict[str, Any]) -> bool:
    if _is_admin(user):
        return True
    owner = job.get("owner_subject")
    return bool(owner) and owner == user.get("sub")


def _filter_meeting(job: dict[str, Any], user: dict[str, Any]) -> dict[str, Any]:
    if not _meeting_allowed(job, user):
        raise HTTPException(status_code=404, detail="meeting not found")
    return job


def _user_principals(user: dict[str, Any]) -> set[str]:
    principals = {"everyone", f"user:{user['sub']}"}
    principals.update(f"group:{g}" for g in user.get("groups") or [] if g)
    return principals


async def _internal_json(method: str, url: str, *, token: str | None = None, **kwargs: Any) -> Any:
    headers = dict(kwargs.pop("headers", {}) or {})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    async with httpx.AsyncClient(timeout=300) as client:
        response = await client.request(method, url, headers=headers, **kwargs)
    if response.is_error:
        detail = response.text[:1500]
        raise HTTPException(status_code=502, detail=f"upstream HTTP {response.status_code}: {detail}")
    if response.content:
        return response.json()
    return None


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"ok": True, "oidc_issuer": OIDC_ISSUER}


@app.get("/login")
async def login(request: Request) -> RedirectResponse:
    canonical = _canonical_redirect(request)
    if canonical is not None:
        return canonical
    if not oidc_metadata:
        await _load_oidc()
    state = secrets.token_urlsafe(24)
    nonce = secrets.token_urlsafe(24)
    request.session["oauth_state"] = state
    request.session["oauth_nonce"] = nonce
    params = {
        "client_id": OIDC_CLIENT_ID,
        "redirect_uri": f"{WEB_PUBLIC_URL}/oauth/callback",
        "response_type": "code",
        "scope": "openid profile email",
        "state": state,
        "nonce": nonce,
    }
    return RedirectResponse(f"{oidc_metadata['authorization_endpoint']}?{urlencode(params)}", status_code=302)


@app.get("/oauth/callback")
async def oauth_callback(request: Request, code: str, state: str) -> RedirectResponse:
    expected_state = request.session.pop("oauth_state", None)
    nonce = request.session.pop("oauth_nonce", None)
    if not expected_state or not secrets.compare_digest(str(expected_state), state):
        raise HTTPException(status_code=400, detail="invalid OIDC state")
    if not nonce:
        raise HTTPException(status_code=400, detail="missing OIDC nonce")

    async with httpx.AsyncClient(verify=_verify(), timeout=30) as client:
        response = await client.post(
            oidc_metadata["token_endpoint"],
            data={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": f"{WEB_PUBLIC_URL}/oauth/callback",
                "client_id": OIDC_CLIENT_ID,
                "client_secret": OIDC_CLIENT_SECRET,
            },
        )
    if response.is_error:
        raise HTTPException(status_code=401, detail=f"OIDC token exchange failed: {response.text[:1000]}")
    token = response.json()
    id_token = token.get("id_token")
    if not isinstance(id_token, str):
        raise HTTPException(status_code=401, detail="OIDC provider returned no ID token")

    def decode_token(raw: str, *, audience: str | None) -> dict[str, Any]:
        header = jwt.get_unverified_header(raw)
        kid = header.get("kid")
        key_data = next(item for item in jwks.get("keys", []) if item.get("kid") == kid)
        key = PyJWK.from_dict(key_data).key
        options = {"require": ["exp", "iat", "sub"]}
        if audience is None:
            options["verify_aud"] = False
        return jwt.decode(
            raw,
            key,
            algorithms=["RS256"],
            audience=audience,
            issuer=OIDC_ISSUER,
            options=options,
        )

    try:
        claims = decode_token(id_token, audience=OIDC_CLIENT_ID)
    except Exception:
        # Keys may have rotated between service startup and login.
        await _load_oidc()
        try:
            claims = decode_token(id_token, audience=OIDC_CLIENT_ID)
        except Exception as exc:
            raise HTTPException(status_code=401, detail=f"invalid ID token: {type(exc).__name__}") from exc

    if claims.get("nonce") != nonce:
        raise HTTPException(status_code=401, detail="invalid OIDC nonce")

    # Keycloak's default realm-role mapper is authoritative in the access token
    # (LibreChat already gates on the same claim). Validate that JWT too rather
    # than assuming realm_access is copied into the ID token.
    access_claims: dict[str, Any] = {}
    access_token = token.get("access_token")
    if isinstance(access_token, str):
        try:
            access_claims = decode_token(access_token, audience=None)
        except Exception:
            await _load_oidc()
            try:
                access_claims = decode_token(access_token, audience=None)
            except Exception as exc:
                raise HTTPException(status_code=401, detail=f"invalid access token: {type(exc).__name__}") from exc
    roles = list(((access_claims.get("realm_access") or claims.get("realm_access") or {}).get("roles") or []))
    if WEB_REQUIRED_ROLE and WEB_REQUIRED_ROLE not in roles:
        request.session.clear()
        raise HTTPException(status_code=403, detail="required runtime role is missing")

    request.session.clear()
    request.session["user"] = {
        "sub": claims["sub"],
        "email": claims.get("email"),
        "name": claims.get("name") or claims.get("preferred_username") or claims.get("email") or claims["sub"],
        "roles": roles,
        "groups": list(access_claims.get("groups") or claims.get("groups") or []),
    }
    request.session["csrf"] = secrets.token_urlsafe(24)
    return RedirectResponse("/", status_code=302)


@app.get("/logout")
async def logout(request: Request) -> RedirectResponse:
    request.session.clear()
    endpoint = oidc_metadata.get("end_session_endpoint")
    if endpoint:
        query = urlencode({"client_id": OIDC_CLIENT_ID, "post_logout_redirect_uri": WEB_PUBLIC_URL})
        return RedirectResponse(f"{endpoint}?{query}", status_code=302)
    return RedirectResponse("/", status_code=302)


@app.get("/api/me")
async def me(request: Request) -> dict[str, Any]:
    user = _user(request)
    return {
        **user,
        "is_admin": _is_admin(user),
        "csrf": request.session.get("csrf"),
        "chat_url": LIBRECHAT_PUBLIC_URL,
    }


@app.get("/api/meetings")
async def meetings_list(request: Request) -> dict[str, Any]:
    user = _user(request)
    payload = await _internal_json("GET", f"{MEETINGS_URL}/v1/meetings", token=meeting_token)
    jobs = [job for job in payload.get("data", []) if isinstance(job, dict) and _meeting_allowed(job, user)]
    return {"data": jobs}


@app.post("/api/meetings", status_code=202)
async def meetings_create(
    request: Request,
    audio: UploadFile = File(...),
    title: str = Form(default="Meeting"),
    participants: str = Form(default=""),
    retain_audio: str = Form(default="0"),
    x_csrf_token: str | None = Header(default=None),
) -> dict[str, Any]:
    user = _user(request)
    _csrf(request, x_csrf_token)
    await audio.seek(0)
    headers = {"Authorization": f"Bearer {meeting_token}"}
    data = {
        "title": title,
        "source": "web",
        "participants": participants,
        "retain_audio": retain_audio,
        "owner_subject": str(user["sub"]),
        "owner_email": str(user.get("email") or ""),
    }
    async with httpx.AsyncClient(timeout=None) as client:
        response = await client.post(
            f"{MEETINGS_URL}/v1/meetings",
            headers=headers,
            data=data,
            files={"audio": (audio.filename or "meeting.audio", audio.file, audio.content_type or "application/octet-stream")},
        )
    await audio.close()
    if response.is_error:
        raise HTTPException(status_code=502, detail=f"meeting upload failed: {response.text[:1500]}")
    return response.json()


@app.get("/api/meetings/{meeting_id}")
async def meeting_get(meeting_id: str, request: Request) -> dict[str, Any]:
    user = _user(request)
    job = await _internal_json("GET", f"{MEETINGS_URL}/v1/meetings/{meeting_id}", token=meeting_token)
    return _filter_meeting(job, user)


@app.get("/api/meetings/{meeting_id}/artifacts/{name}")
async def meeting_artifact(meeting_id: str, name: str, request: Request) -> Response:
    user = _user(request)
    job = await _internal_json("GET", f"{MEETINGS_URL}/v1/meetings/{meeting_id}", token=meeting_token)
    _filter_meeting(job, user)
    async with httpx.AsyncClient(timeout=60) as client:
        response = await client.get(
            f"{MEETINGS_URL}/v1/meetings/{meeting_id}/artifacts/{name}",
            headers={"Authorization": f"Bearer {meeting_token}"},
        )
    if response.status_code == 404:
        raise HTTPException(status_code=404, detail="artifact not found")
    if response.is_error:
        raise HTTPException(status_code=502, detail=f"artifact fetch failed: {response.text[:1000]}")
    return Response(content=response.content, media_type=response.headers.get("content-type", "text/plain"))


@app.post("/api/meetings/{meeting_id}/publish")
async def meeting_publish(
    meeting_id: str,
    request: Request,
    body: dict[str, Any] | None = Body(default=None),
    x_csrf_token: str | None = Header(default=None),
) -> dict[str, Any]:
    user = _user(request)
    _csrf(request, x_csrf_token)
    job = await _internal_json("GET", f"{MEETINGS_URL}/v1/meetings/{meeting_id}", token=meeting_token)
    _filter_meeting(job, user)
    body = body or {}
    visibility = str(body.get("visibility") or "private")
    if visibility == "private":
        acl = [f"user:{user['sub']}"]
    elif visibility == "everyone":
        acl = ["everyone"]
    else:
        raise HTTPException(status_code=400, detail="visibility must be private or everyone")
    result = await _internal_json(
        "POST",
        f"{MEETINGS_URL}/v1/meetings/{meeting_id}/publish",
        token=meeting_token,
        json={"acl_principals": acl},
    )
    return result


@app.get("/api/knowledge")
async def knowledge_list(request: Request) -> dict[str, Any]:
    user = _user(request)
    payload = await _internal_json(
        "GET", f"{KNOWLEDGE_URL}/internal/documents", token=KNOWLEDGE_QUERY_TOKEN
    )
    if _is_admin(user):
        return payload
    principals = _user_principals(user)
    visible = []
    for doc in payload.get("data", []):
        if principals.intersection(set(doc.get("acl_principals") or [])):
            visible.append(doc)
    return {"data": visible}


@app.get("/api/knowledge/search")
async def knowledge_search(request: Request, q: str) -> dict[str, Any]:
    user = _user(request)
    if not q.strip():
        return {"data": []}
    payload = await _internal_json(
        "POST",
        f"{KNOWLEDGE_URL}/internal/retrieve",
        token=KNOWLEDGE_QUERY_TOKEN,
        headers={
            "X-Runtime-Subject": str(user["sub"]),
            "X-Runtime-User-Email": str(user.get("email") or ""),
            "X-Runtime-Groups": ",".join(user.get("groups") or []),
        },
        json={"query": q, "limit": 8},
    )
    return {"data": payload.get("evidence", [])}


async def _probe(name: str, url: str, *, headers: dict[str, str] | None = None) -> dict[str, Any]:
    try:
        async with httpx.AsyncClient(timeout=3, verify=_verify()) as client:
            response = await client.get(url, headers=headers)
        return {"name": name, "ok": response.is_success, "status": response.status_code}
    except Exception as exc:
        return {"name": name, "ok": False, "error": type(exc).__name__}


@app.get("/api/status")
async def runtime_status(request: Request) -> dict[str, Any]:
    _user(request)
    services = []
    for name, url, headers in [
        ("Local AI", f"{LITELLM_URL}/health/liveliness", None),
        ("Knowledge", f"{KNOWLEDGE_URL}/health", None),
        ("Meetings", f"{MEETINGS_URL}/health", None),
        ("Speech", f"{SPEACHES_URL}/health", None),
        ("Chat", f"{LIBRECHAT_INTERNAL_URL}/api/config", None),
        ("Metrics", f"{PROMETHEUS_URL}/-/ready", None),
        ("Identity", f"{OIDC_ISSUER}/.well-known/openid-configuration", None),
    ]:
        services.append(await _probe(name, url, headers=headers))

    models: dict[str, Any] = {"llm": [], "speech": []}
    try:
        data = await _internal_json("GET", f"{LITELLM_URL}/v1/models", headers={"Authorization": f"Bearer {os.environ['LITELLM_MASTER_KEY']}"})
        models["llm"] = [item.get("id") for item in data.get("data", [])]
    except Exception:
        pass
    try:
        data = await _internal_json("GET", f"{SPEACHES_URL}/v1/models", headers={"Authorization": f"Bearer {os.environ['SPEACHES_API_KEY']}"})
        models["speech"] = [item.get("id") for item in data.get("data", [])]
    except Exception:
        pass

    web_search: dict[str, Any] = {"name": "Public web", "ok": False, "state": "unavailable"}
    try:
        data = await _internal_json("GET", f"{WEB_SEARCH_URL}/health")
        state = str(data.get("state") or "unknown")
        web_search = {
            "name": "Public web",
            "ok": bool(data.get("ok")),
            "state": state,
            "provider": data.get("provider"),
            "configured": bool(data.get("configured")),
        }
    except Exception as exc:
        web_search["error"] = type(exc).__name__
    services.append(web_search)
    return {"services": services, "models": models, "runtime_version": os.getenv("RUNTIME_VERSION", "unknown")}


@app.get("/api/audit")
async def audit(request: Request, limit: int = 30) -> dict[str, Any]:
    user = _user(request)
    if not _is_admin(user):
        raise HTTPException(status_code=403, detail="administrator role required")
    limit = max(1, min(limit, 100))
    if not AUDIT_LOG_PATH.is_file():
        return {"data": []}
    lines = AUDIT_LOG_PATH.read_text(errors="replace").splitlines()[-limit:]
    events = []
    for line in reversed(lines):
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(item, dict):
            events.append(item)
    return {"data": events}


@app.get("/")
async def index(request: Request) -> Response:
    canonical = _canonical_redirect(request)
    if canonical is not None:
        return canonical
    return FileResponse(STATIC_DIR / "index.html")


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException) -> Response:
    # Browser navigation to the app should get the sign-in screen rather than a JSON 401.
    if request.url.path.startswith("/api/"):
        return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})
