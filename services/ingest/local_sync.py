"""Local-directory connector for the Knowledge Service ingestion contract.

This connector is intentionally small: it discovers files from a manifest,
translates the manifest ACLs into canonical principals, and sends one full
source snapshot to the internal knowledge API. It never writes Postgres.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_token(path: Path) -> str:
    token = path.read_text().strip()
    if not token:
        raise SystemExit(f"empty ingestion token: {path}")
    return token


def load_payload(root: Path, manifest_path: Path) -> tuple[str, dict[str, Any]]:
    manifest = json.loads(manifest_path.read_text())
    source = manifest.get("source") or {}
    source_id = source.get("id")
    source_type = source.get("type", "local")
    if not source_id:
        raise SystemExit("manifest source.id is required")

    documents = []
    for item in manifest.get("documents", []):
        relative = Path(item["path"])
        path = (root / relative).resolve()
        try:
            path.relative_to(root.resolve())
        except ValueError as exc:
            raise SystemExit(f"document path escapes source root: {relative}") from exc
        if not path.is_file():
            raise SystemExit(f"document does not exist: {path}")

        content = path.read_text(encoding="utf-8")
        digest = sha256_text(content)
        documents.append(
            {
                "source_document_id": item.get("id") or relative.as_posix(),
                "version": item.get("version") or digest[:16],
                "uri": item.get("uri") or f"local://{source_id}/{relative.as_posix()}",
                "title": item.get("title") or path.stem.replace("_", " ").title(),
                "mime_type": item.get("mime_type")
                or mimetypes.guess_type(path.name)[0]
                or "text/plain",
                "content": content,
                "content_hash": digest,
                "acl_principals": item.get("acl_principals") or [],
            }
        )

    return source_id, {
        "source_type": source_type,
        "full_snapshot": True,
        "documents": documents,
    }


def post_sync(url: str, token: str, payload: dict[str, Any]) -> dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"knowledge sync failed: HTTP {exc.code}: {detail}") from exc


def main() -> None:
    parser = argparse.ArgumentParser(description="Sync a local source into Knowledge Service")
    parser.add_argument("--root", default="/source")
    parser.add_argument("--manifest", default="/source/manifest.json")
    parser.add_argument("--knowledge-url", default="http://knowledge:8090")
    parser.add_argument("--token-file", default="/run/secrets/knowledge_ingest_token")
    args = parser.parse_args()

    source_id, payload = load_payload(Path(args.root), Path(args.manifest))
    endpoint = f"{args.knowledge_url.rstrip('/')}/internal/sources/{source_id}/sync"
    result = post_sync(endpoint, read_token(Path(args.token_file)), payload)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
