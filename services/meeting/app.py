from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field, field_validator

DATA_ROOT = Path(os.getenv("MEETING_DATA_ROOT", "/var/lib/runtime-meetings"))
API_TOKEN_FILE = Path(os.getenv("MEETING_API_TOKEN_FILE", "/run/secrets/meeting_api_token"))
KNOWLEDGE_INGEST_TOKEN_FILE = Path(
    os.getenv("KNOWLEDGE_INGEST_TOKEN_FILE", "/run/secrets/knowledge_ingest_token")
)
KNOWLEDGE_URL = os.getenv("KNOWLEDGE_URL", "http://knowledge:8090").rstrip("/")
MAX_UPLOAD_BYTES = int(os.getenv("MEETING_MAX_UPLOAD_BYTES", str(2 * 1024**3)))
PROCESSOR = Path(os.getenv("MEETING_PROCESSOR", "/app/meeting.py"))

api_token: str | None = None
knowledge_ingest_token: str | None = None
job_queue: asyncio.Queue[str] | None = None
worker_task: asyncio.Task[None] | None = None

FINAL_STATUSES = {"draft", "published", "failed"}
def is_safe_artifact_name(name: str) -> bool:
    return bool(name) and name == Path(name).name and not name.startswith(".")



def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_csv(raw: str | None) -> list[str]:
    if not raw:
        return []
    return [part.strip() for part in raw.split(",") if part.strip()]


def parse_bool(raw: str | bool | None, default: bool) -> bool:
    if raw is None:
        return default
    if isinstance(raw, bool):
        return raw
    return raw.strip().lower() not in {"0", "false", "no", "off"}


def safe_filename(name: str | None) -> str:
    candidate = Path(name or "meeting.audio").name
    candidate = re.sub(r"[^A-Za-z0-9._ -]+", "_", candidate).strip(" .")
    return candidate or "meeting.audio"


def job_dir(job_id: str) -> Path:
    if not re.fullmatch(r"mtg_[A-Za-z0-9_-]+", job_id):
        raise HTTPException(status_code=404, detail="meeting not found")
    path = DATA_ROOT / job_id
    if not path.is_dir():
        raise HTTPException(status_code=404, detail="meeting not found")
    return path


def job_file(job_id: str) -> Path:
    return job_dir(job_id) / "job.json"


def read_job(job_id: str) -> dict[str, Any]:
    try:
        payload = json.loads(job_file(job_id).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=500, detail=f"invalid meeting state: {exc}") from exc
    if not isinstance(payload, dict):
        raise HTTPException(status_code=500, detail="invalid meeting state")
    return payload


def write_job(job: dict[str, Any]) -> None:
    directory = DATA_ROOT / str(job["id"])
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "job.json"
    tmp = directory / ".job.json.tmp"
    tmp.write_text(json.dumps(job, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(path)


def require_api_auth(authorization: str | None) -> None:
    assert api_token is not None
    if not secrets.compare_digest(authorization or "", f"Bearer {api_token}"):
        raise HTTPException(status_code=401, detail="invalid meeting API credential")


def public_job(job: dict[str, Any]) -> dict[str, Any]:
    result = dict(job)
    result.pop("input_path", None)
    artifacts = DATA_ROOT / str(job["id"]) / "artifacts"
    result["artifacts"] = sorted(
        path.name for path in artifacts.iterdir() if path.is_file() and is_safe_artifact_name(path.name)
    ) if artifacts.is_dir() else []
    return result


def new_job_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"mtg_{stamp}_{secrets.token_hex(4)}"


async def save_upload(upload: UploadFile, destination: Path) -> int:
    total = 0
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        with destination.open("wb") as f:
            while chunk := await upload.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_UPLOAD_BYTES:
                    raise HTTPException(status_code=413, detail="meeting audio exceeds upload limit")
                f.write(chunk)
    except Exception:
        destination.unlink(missing_ok=True)
        raise
    finally:
        await upload.close()
    return total


def processor_env(job: dict[str, Any]) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "MEETING_ID": str(job["id"]),
            "MEETING_AUDIO_PATH": str(job["input_path"]),
            "MEETING_OUTPUT_PATH": str(DATA_ROOT / str(job["id"]) / "artifacts"),
            "MEETING_AUDIO_NAME": str(job["audio_name"]),
            "MEETING_TITLE": str(job["title"]),
            "MEETING_PARTICIPANTS": ",".join(job.get("participants") or []),
            "MEETING_VOCAB": ",".join(job.get("vocabulary") or []),
            "MEETING_SPEAKER_MAP": str(job.get("speaker_map") or ""),
            "MEETING_DIARIZE": "1" if job.get("diarize", True) else "0",
            "MEETING_REQUIRE_DIARIZATION": "1" if job.get("require_diarization", False) else "0",
            "MEETING_NORMALIZE": "1" if job.get("normalize", True) else "0",
            "MEETING_SUMMARY": "1" if job.get("summary", True) else "0",
            "MEETING_DEBUG_LLM_RESPONSES": "1" if job.get("debug_llm_responses", False) else "0",
        }
    )
    return env


def run_processor(job_id: str) -> tuple[int, str]:
    job = read_job(job_id)
    artifacts = DATA_ROOT / job_id / "artifacts"
    artifacts.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        [sys.executable, str(PROCESSOR)],
        env=processor_env(job),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    log = completed.stdout or ""
    (artifacts / "worker.log").write_text(log)
    return completed.returncode, log


async def process_job(job_id: str) -> None:
    job = read_job(job_id)
    if job.get("status") not in {"queued", "processing"}:
        return
    job["status"] = "processing"
    job["updated_at"] = now_iso()
    job["error"] = None
    write_job(job)

    try:
        returncode, log = await asyncio.to_thread(run_processor, job_id)
        job = read_job(job_id)
        if returncode != 0:
            tail = "\n".join(log.strip().splitlines()[-20:])
            raise RuntimeError(f"meeting processor exited {returncode}: {tail}")

        record_path = DATA_ROOT / job_id / "artifacts" / "meeting.json"
        record = json.loads(record_path.read_text())
        job["duration_seconds"] = record.get("duration_seconds")
        job["status"] = "draft"
        job["processed_at"] = now_iso()
        job["updated_at"] = job["processed_at"]
        job["error"] = None
        if not job.get("retain_audio", False):
            Path(str(job["input_path"])).unlink(missing_ok=True)
            job["audio_retained"] = False
        else:
            job["audio_retained"] = True
        write_job(job)
    except Exception as exc:
        job = read_job(job_id)
        job["status"] = "failed"
        job["updated_at"] = now_iso()
        job["error"] = f"{type(exc).__name__}: {exc}"
        job["audio_retained"] = Path(str(job.get("input_path", ""))).is_file()
        write_job(job)


async def worker() -> None:
    assert job_queue is not None
    while True:
        job_id = await job_queue.get()
        try:
            await process_job(job_id)
        finally:
            job_queue.task_done()


async def recover_jobs() -> None:
    assert job_queue is not None
    for state_path in sorted(DATA_ROOT.glob("mtg_*/job.json")):
        try:
            job = json.loads(state_path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if job.get("status") not in {"queued", "processing"}:
            continue
        input_path = Path(str(job.get("input_path") or ""))
        if input_path.is_file():
            job["status"] = "queued"
            job["updated_at"] = now_iso()
            job["error"] = "recovered after meeting service restart"
            write_job(job)
            await job_queue.put(str(job["id"]))
        else:
            job["status"] = "failed"
            job["updated_at"] = now_iso()
            job["error"] = "meeting service restarted but source audio was unavailable"
            write_job(job)


@asynccontextmanager
async def lifespan(_: FastAPI):
    global api_token, knowledge_ingest_token, job_queue, worker_task
    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    api_token = API_TOKEN_FILE.read_text().strip()
    knowledge_ingest_token = KNOWLEDGE_INGEST_TOKEN_FILE.read_text().strip()
    if not api_token:
        raise RuntimeError("meeting API token is empty")
    if not knowledge_ingest_token:
        raise RuntimeError("knowledge ingestion token is empty")
    job_queue = asyncio.Queue()
    worker_task = asyncio.create_task(worker())
    await recover_jobs()
    try:
        yield
    finally:
        if worker_task is not None:
            worker_task.cancel()
            try:
                await worker_task
            except asyncio.CancelledError:
                pass


app = FastAPI(title="Meeting Service", version="0.1", lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, Any]:
    counts: dict[str, int] = {}
    for state_path in DATA_ROOT.glob("mtg_*/job.json"):
        try:
            status = str(json.loads(state_path.read_text()).get("status") or "unknown")
        except Exception:
            status = "invalid"
        counts[status] = counts.get(status, 0) + 1
    return {"ok": True, "jobs": counts}


@app.post("/v1/meetings", status_code=202)
async def create_meeting(
    audio: UploadFile = File(...),
    title: str = Form(default="Meeting"),
    source: str = Form(default="upload"),
    participants: str = Form(default=""),
    vocabulary: str = Form(default=""),
    speaker_map: str = Form(default=""),
    diarize: str = Form(default="1"),
    require_diarization: str = Form(default="0"),
    normalize: str = Form(default="1"),
    summary: str = Form(default="1"),
    retain_audio: str = Form(default="0"),
    debug_llm_responses: str = Form(default="0"),
    owner_subject: str = Form(default=""),
    owner_email: str = Form(default=""),
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    require_api_auth(authorization)
    assert job_queue is not None

    job_id = new_job_id()
    directory = DATA_ROOT / job_id
    input_dir = directory / "input"
    artifacts_dir = directory / "artifacts"
    input_dir.mkdir(parents=True, exist_ok=False)
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    filename = safe_filename(audio.filename)
    input_path = input_dir / filename

    try:
        uploaded_bytes = await save_upload(audio, input_path)
        if uploaded_bytes == 0:
            raise HTTPException(status_code=400, detail="meeting audio is empty")

        job: dict[str, Any] = {
            "id": job_id,
            "schema_version": 1,
            "status": "queued",
            "title": title.strip() or "Meeting",
            "source": (source.strip() or "upload")[:128],
            "audio_name": filename,
            "audio_bytes": uploaded_bytes,
            "input_path": str(input_path),
            "audio_retained": True,
            "retain_audio": parse_bool(retain_audio, False),
            "participants": parse_csv(participants),
            "vocabulary": parse_csv(vocabulary),
            "owner_subject": owner_subject.strip() or None,
            "owner_email": owner_email.strip() or None,
            "speaker_map": speaker_map.strip(),
            "diarize": parse_bool(diarize, True),
            "require_diarization": parse_bool(require_diarization, False),
            "normalize": parse_bool(normalize, True),
            "summary": parse_bool(summary, True),
            "debug_llm_responses": parse_bool(debug_llm_responses, False),
            "created_at": now_iso(),
            "updated_at": now_iso(),
            "processed_at": None,
            "published_at": None,
            "acl_principals": [],
            "knowledge_sync": None,
            "duration_seconds": None,
            "error": None,
        }
        write_job(job)
        await job_queue.put(job_id)
        return public_job(job)
    except Exception:
        shutil.rmtree(directory, ignore_errors=True)
        raise


@app.get("/v1/meetings")
async def list_meetings(
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    require_api_auth(authorization)
    jobs: list[dict[str, Any]] = []
    for state_path in DATA_ROOT.glob("mtg_*/job.json"):
        try:
            job = json.loads(state_path.read_text())
            if isinstance(job, dict):
                jobs.append(public_job(job))
        except Exception:
            continue
    jobs.sort(key=lambda item: str(item.get("created_at") or ""), reverse=True)
    return {"data": jobs}


@app.get("/v1/meetings/{job_id}")
async def get_meeting(
    job_id: str,
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    require_api_auth(authorization)
    return public_job(read_job(job_id))


@app.get("/v1/meetings/{job_id}/artifacts/{artifact_name}")
async def get_artifact(
    job_id: str,
    artifact_name: str,
    authorization: str | None = Header(default=None),
) -> FileResponse:
    require_api_auth(authorization)
    if not is_safe_artifact_name(artifact_name):
        raise HTTPException(status_code=404, detail="artifact not found")
    path = job_dir(job_id) / "artifacts" / artifact_name
    if not path.is_file():
        raise HTTPException(status_code=404, detail="artifact not found")
    return FileResponse(path)


class PublishRequest(BaseModel):
    acl_principals: list[str] = Field(min_length=1)

    @field_validator("acl_principals")
    @classmethod
    def validate_acl_principals(cls, value: list[str]) -> list[str]:
        cleaned = sorted({item.strip() for item in value if item.strip()})
        if not cleaned:
            raise ValueError("at least one ACL principal is required")
        for principal in cleaned:
            if principal != "everyone" and not principal.startswith(("user:", "group:")):
                raise ValueError("ACL principals must be everyone, user:<id>, or group:<id>")
        return cleaned


@app.post("/v1/meetings/{job_id}/publish")
async def publish_meeting(
    job_id: str,
    request: PublishRequest,
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    require_api_auth(authorization)
    assert knowledge_ingest_token is not None
    job = read_job(job_id)
    if job.get("status") not in {"draft", "published"}:
        raise HTTPException(status_code=409, detail="only completed draft meetings can be published")

    transcript_path = job_dir(job_id) / "artifacts" / "normalized_transcript.md"
    if not transcript_path.is_file():
        raise HTTPException(status_code=409, detail="normalized transcript is unavailable")
    content = transcript_path.read_text()
    content_hash = hashlib.sha256(content.encode("utf-8")).hexdigest()

    payload = {
        "source_type": "meeting",
        "full_snapshot": False,
        "documents": [
            {
                "source_document_id": job_id,
                "version": content_hash,
                "uri": f"meeting://{job_id}",
                "title": str(job.get("title") or "Meeting"),
                "mime_type": "text/markdown",
                "content": content,
                "content_hash": content_hash,
                "modified_at": now_iso(),
                "acl_principals": request.acl_principals,
            }
        ],
    }
    async with httpx.AsyncClient(timeout=300) as client:
        response = await client.post(
            f"{KNOWLEDGE_URL}/internal/sources/meetings/sync",
            headers={"Authorization": f"Bearer {knowledge_ingest_token}"},
            json=payload,
        )
    if response.is_error:
        raise HTTPException(
            status_code=502,
            detail=f"knowledge publication failed: HTTP {response.status_code}: {response.text[:1000]}",
        )

    job = read_job(job_id)
    job["status"] = "published"
    job["published_at"] = now_iso()
    job["updated_at"] = job["published_at"]
    job["acl_principals"] = request.acl_principals
    job["knowledge_sync"] = response.json()
    write_job(job)
    return public_job(job)
