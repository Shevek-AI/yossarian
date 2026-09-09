# Yossarian

*Private AI with explicit trust boundaries.*

An open-source reference implementation for private/local organisational AI using
pinned, inspectable components. The point of this repository is to make the
architecture concrete: local inference, identity, permission-aware retrieval,
meeting memory, audit/observability, and explicitly governed external tools.

This is a **reference implementation and engineering starting point**, not a
turnkey enterprise appliance, compliance claim, or certified security boundary.
It is intentionally small enough for one competent engineer to understand.

Current high-level paths:

```text
                         +-> Private Knowledge (ACL RAG, NO external tools)
                         |       |
                         |       +-> Knowledge Service -> Postgres + pgvector
                         |                               -> LiteLLM -> vLLM -> local Qwen
LibreChat / Runtime Web -+
                         +-> General AI (NO organisational retrieval)
                                 |
                                 +-> LiteLLM -> vLLM -> local Qwen
                                 +-> Public Web Search MCP -> Brave (optional egress)

Meetings -> Speaches/faster-whisper + diarization -> local LLM -> draft/review/publish
local connector -> canonical document sync -> Knowledge Service
OIDC -> Caddy local TLS -> Keycloak (development stand-in)
Prometheus <- vLLM / LiteLLM / Keycloak / NVIDIA DCGM
```

The key security idea is **capability separation rather than prompt obedience**.
Retrieved documents are untrusted input. The private-knowledge route therefore
refuses tool-calling capability altogether; public-web tools live on a separate
chat path that does not retrieve organisational documents. See
[`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md).

## Current components

- **vLLM 0.28.0** — local OpenAI-compatible inference; internal-only.
- **LiteLLM 1.98.0** — stable OpenAI-compatible inference gateway; development port is loopback-only.
- **Knowledge Service** — a deliberately small first-party ingestion/query boundary and permission-aware RAG proxy.
- **Postgres 18 + pgvector 0.8.6** — retrieval store; private to the runtime network.
- **FastEmbed 0.8.0 / BAAI bge-small-en-v1.5** — CPU embedding baseline for the retrieval slice.
- **Runtime Web** — first-party browser control surface/BFF for Meetings, Knowledge and Governance; OIDC session terminates server-side and internal service credentials never reach browser JavaScript.
- **Public Web Search** — bounded MCP search service for explicitly enabled public-web egress; disabled by default and isolated from runtime data services.
- **LibreChat 0.8.7** — replaceable human chat UI; development port is loopback-only.
- **MongoDB 8.0.20** — LibreChat-only UI state; no host port.
- **Keycloak 26.7.3** — development stand-in for the organisation's OIDC identity provider.
- **Caddy 2.11.4** — local TLS termination for the development OIDC issuer.
- **Qwen3-8B-AWQ** — deliberately modest first model for a 16 GB NVIDIA GPU.
- **Prometheus 3.14.0** — private runtime metrics TSDB; development UI is loopback-only.
- **NVIDIA DCGM Exporter 4.6.0-4.8.3** — GPU telemetry; no host port.
- **Runtime audit callback** — append-only request metadata; prompt/response bodies are never copied into audit events.
- **Speaches 0.9.0-rc.3 / faster-whisper** — OpenAI-compatible local speech-to-text; CPU/int8 in this development slice so it does not contend with vLLM for GPU memory.

These are development pins, not yet a certified release matrix.

## Prerequisites

Ubuntu + Docker Compose + an NVIDIA GPU configured with NVIDIA Container Toolkit.

Sanity check:

```bash
nvidia-smi

docker run --rm --gpus all \
  nvidia/cuda:13.0.2-base-ubuntu24.04 \
  nvidia-smi
```

## Start

```bash
./scripts/bootstrap.sh
make config
docker compose down
./scripts/up.sh
```

The first knowledge start also downloads the small CPU embedding model. Both the vLLM model and the embedding model are cached in persistent volumes/host caches.

Watch startup:

```bash
docker compose logs -f web web-search keycloak caddy vllm litellm knowledge postgres meetings speaches librechat prometheus dcgm-exporter
```

Then:

```bash
./scripts/smoke.sh
```

Startup provisions the configured STT and diarization models into the persistent Speaches cache. A fresh cache therefore makes the first `up.sh` slower, but a healthy runtime is also capability-ready rather than waiting to 404 on the first speech request.

Open the runtime control surface:

```text
http://localhost:8080
```

LibreChat remains available as the replaceable chat client at `http://localhost:3080`; Runtime Web links to it rather than reimplementing chat in this slice. The Runtime Web **Chat** page makes the security boundary explicit before launch, and LibreChat uses matching endpoint labels:

- **Private Knowledge** — ACL-aware organisational retrieval, local inference, and external tool/function capability rejected by the runtime. This is the recommended default for internal work.
- **General AI** — local inference with no organisational retrieval; external tools such as Public Web Search may be available when policy enables them.

Treat them as separate conversation modes. Do not move private material into a General AI conversation merely to gain external-tool capability.

## OIDC test

Keycloak is a local stand-in only. Production should normally point the runtime at the organisation's Entra/Okta/Google/Keycloak issuer instead of shipping another identity silo.

The local issuer is:

```text
https://auth.localhost:8443
```

Caddy generates a development CA. For the browser:

```bash
make trust-dev-ca
```

Restart the browser after installing it.

Get the generated development credentials:

```bash
make identity-info
```

Development users:

- `allowed@example.test` — `runtime-user` + development `runtime-admin`, retrieval scope `public + engineering`.
- `finance@example.test` — `runtime-user`, retrieval scope `public + finance`.
- `staff@example.test` — `runtime-user`, retrieval scope `public only`.
- `denied@example.test` — lacks `runtime-user` and must be rejected at login.

The synthetic Keycloak users have fixed OIDC subjects and Keycloak data is now persisted, so ordinary `docker compose down/up` cycles do not change identity. `docker compose down -v` deliberately resets it.

If you deliberately reset or replace the development Keycloak realm while preserving LibreChat state, the test account can retain an old OpenID subject. If LibreChat reports an OpenID ID mismatch, run:

```bash
make reset-dev-users
```

Then sign in through SSO again.

Local email login remains enabled only as a development break-glass path. The production profile should remove local password login entirely.

## Runtime Web control surface

`http://localhost:8080` is the development front door for the runtime. It is deliberately a thin backend-for-frontend rather than another copy of the inference stack.

Current UX:

- OIDC sign-in with the same `runtime-user` gate as chat;
- Meetings list, upload, browser microphone recording, processing status, draft review and explicit publication;
- Knowledge source inventory plus permission-aware retrieval search;
- Governance/status view for the development admin, including service readiness, installed models and content-free audit metadata;
- Chat opens an explicit capability-selection page before launching LibreChat: **Private Knowledge** (organisational retrieval, no external tools) or **General AI** (no organisational retrieval, optional policy-gated external tools).

The browser never receives the Meetings API token, Knowledge ingestion token, LiteLLM master key or Speaches key. The web backend holds those private credentials and derives meeting ownership / publication ACLs from the authenticated OIDC session. Mutating browser requests also require a per-session CSRF token.

The browser recorder uses the standard `MediaRecorder` API. `localhost` is treated as a secure browser context, so this development slice can request microphone access over loopback HTTP; production should use normal HTTPS/TLS.

Fresh Keycloak realms import the web OIDC client from the tracked realm template. `bootstrap.sh` renders that template into a dedicated `.runtime-keycloak-import/` directory named for the configured realm and mounts the directory over Keycloak's import path; import files therefore do not accumulate inside the persistent Keycloak data volume. `up.sh` also runs an idempotent development provisioner so an already-persistent Keycloak volume gets the new client without deleting identity state.

Run the non-interactive boundary check:

```bash
make web-smoke
```

Then open `http://localhost:8080` and sign in as `allowed@example.test` for the admin/governance view.

`WEB_PUBLIC_URL` is the canonical browser origin. In development, `127.0.0.1` and `localhost` reach the same socket but are different cookie origins. Runtime Web therefore redirects alternate loopback navigation to the configured public URL **before** creating OIDC state; this avoids losing the session cookie during the callback.

## Controlled public web search

Public-web access is a separate, explicit egress capability rather than something hidden inside the model or retrieval path:

```text
LibreChat -> Public Web Search MCP -> configured search provider
                  |
                  +-> bounded search metadata/snippets only
                  +-> no arbitrary result-URL fetching
```

The service is **disabled by default**. With the default configuration, no public-web query is sent outside the runtime. To enable the development Brave provider, set these values in `.env`:

```bash
WEB_SEARCH_ENABLED=1
BRAVE_SEARCH_API_KEY=<provider-key>
```

Then rebuild/restart the affected services (or simply run `./scripts/up.sh`):

```bash
docker compose up -d --build web-search librechat web
```

Check the private MCP boundary without making an external query:

```bash
make web-search-smoke
make security-smoke
```

In LibreChat, use the **General AI** endpoint and enable **Public Web Search** when current/public information is required. The **Private Knowledge** endpoint rejects tool capability by design. The user search query is then sent to the configured external search provider. Returned titles, URLs and snippets are marked as untrusted public-web data and are not treated as organisational evidence. The service does not follow or fetch arbitrary result URLs in this slice.

LibreChat presents MCP tools to the OpenAI-compatible model with `tool_choice=auto`. The local Qwen3/vLLM server therefore starts with automatic tool choice enabled and the Hermes tool-call parser (`--enable-auto-tool-choice --tool-call-parser hermes`), while retaining the Qwen3 reasoning parser. The web-search smoke also sends a no-egress dummy auto-tool request through LiteLLM so this contract cannot silently regress while the MCP service itself remains healthy.

Every attempted web-search operation writes content-free egress metadata to the shared audit log (provider, status, result count and duration); query text and result contents are deliberately excluded.

The network boundary is also explicit: the search service has no host port and joins only the separate `tooling` bridge. It is not attached to the `runtime` network, so it has no direct network path to Postgres, vLLM, Knowledge, Keycloak or Meetings. LibreChat and Runtime Web bridge the two networks because they need to consume the tool/status endpoint.

This means deployment claims can be precise:

- **web search disabled:** the runtime does not use this public-web egress path;
- **web search enabled and used:** the search query leaves the environment for the configured provider.

### Prompt injection and external egress

Document prompt injection is treated as a real threat, but **ingest-time prompt
classification is not used as a security boundary**. A malicious document can be
subtle, obfuscated, or simply contain text that resembles normal instructions.
The runtime therefore does not attempt to decide that a document is "safe" before
indexing it.

Instead:

- retrieved organisational text is marked and injected as untrusted user-level data;
- the `Private Knowledge` route rejects OpenAI tool/function capability;
- the `General AI` route permits tools but performs no organisational retrieval;
- Public Web Search is disabled by default, separately network-isolated, bounded, and audited without query contents.

This prevents the direct indirect-prompt-injection chain `malicious document ->
model tool call -> public search query containing private data` in a single model
turn. It does **not** make prompt injection solved in general: users can still copy
private text into a public-tool conversation, compromised clients can misuse their
own authority, and future tools/connectors must preserve the same trust boundary.
See the threat model for the remaining assumptions.

## Document ingress and permission-aware retrieval

Knowledge no longer appears magically at service startup. A connector must explicitly sync a source through the internal canonical ingestion API:

```text
source connector
      |
      +-> canonical document + provenance + source ACL
                         |
                  Knowledge Service
                         |
             chunk -> embed -> Postgres
```

For the development fixture:

```bash
make ingest
```

The `ingest` container is a one-shot local-directory connector. It can read the fixture source and call the private ingestion API, but it cannot access Postgres. The ingestion endpoint requires a runtime-generated bearer credential mounted from `.runtime-secrets/knowledge_ingest_token`.

A full source sync also owns deletion semantics: a document removed from the source manifest is deleted from the index on the next sync. Unchanged document content is not re-embedded; ACL/metadata can still be updated independently.

The canonical record currently carries `source_id`, `source_type`, source document ID/version, URI/title/MIME type, content hash/text, modification time and ACL principals. ACL principals use the future-compatible forms `everyone`, `user:<id>` and `group:<id>`. The local connector only handles UTF-8 text/Markdown for now; PDF/DOCX extraction belongs behind the same connector contract rather than in the query path.

The development corpus is tracked under `fixtures/knowledge/`:

```text
public/employee_handbook.md
engineering/project_kookaburra.md
finance/fy27_budget.md
```

The fixture manifest carries document ACL principals directly. Production connectors should translate the source system's real user/group ACLs into the same canonical principal contract.

Run the critical authorization test directly:

```bash
make retrieval-smoke
```

Exercise idempotence, ACL-only updates, content updates and deletion:

```bash
make ingress-lifecycle-smoke
```

It proves:

```text
allowed@example.test -> public + engineering, never finance
finance@example.test -> public + finance, never engineering
staff@example.test   -> public only
```

The security boundary is in the SQL query: a document ACL must match `everyone`, the authenticated `user:<OIDC-sub>`, or a delegated `group:<id>` **before** vector ranking returns chunks to Python or the LLM. We do not retrieve everything and filter afterwards.

LibreChat sends each authenticated request through the internal knowledge proxy. The proxy retrieves only authorized context, injects that context as untrusted reference data, then forwards the OpenAI-compatible request to LiteLLM. The service has no host port.

This is intentionally a retrieval baseline, not a benchmark winner. It uses dense pgvector search only. Lexical/BM25, RRF and reranking should be added only after we have a representative corpus and measurements.


## Local speech-to-text

Speaches provides the private `speaches:8000` OpenAI-compatible transcription endpoint used by Meetings and the explicit transcription helper. The service itself has no host port. LibreChat is configured with the same private endpoint and an exact `speaches:8000` SSRF exemption, but its composer STT is disabled by default in this release; see below.

The development default is `Systran/faster-distil-whisper-small.en` on CPU/int8. This deliberately leaves the NVIDIA GPU to vLLM; model choice/device placement can be benchmarked later on representative meeting audio.

Run the tracked audio fixture:

```bash
make transcription-smoke
```

Transcribe an arbitrary local recording without exposing a speech port:

```bash
make transcribe AUDIO=/path/to/meeting.m4a
```

The helper copies the recording to a temporary path inside the running Speaches container, transcribes it, prints only the returned text, and removes the temporary copy. This is a development convenience rather than the eventual meeting-ingestion/storage policy.

LibreChat v0.8.7 has an upstream mismatch between the configuration schema and the client runtime for the external STT default ([LibreChat #14726](https://github.com/danny-avila/LibreChat/issues/14726)). Setting `engineSTT: external` makes v0.8.7 refuse to start; setting the schema-valid `openai` value can fall through to browser speech recognition instead of the configured private endpoint. Yossarian therefore leaves LibreChat composer STT **disabled by default** rather than risk unexpected speech egress. Use the Meetings recorder or `make transcribe` for local speech in v0.1. Revisit this when the upstream fix is available in a stable LibreChat release. Text-to-speech remains disabled.

## Audit and metrics

LibreChat forwards authenticated user/request identifiers into the internal path. Audit records include application user ID, OpenID subject where available, email, model, token counts, latency and status. Prompt and response bodies are deliberately absent.

After sending a chat message:

```bash
make audit
```

Prometheus is available only on host loopback in development:

```text
http://localhost:9090
```

It scrapes vLLM, LiteLLM, Keycloak and NVIDIA DCGM metrics.

## Useful commands

```bash
make status
make web
make web-smoke
make web-search-smoke
make security-smoke
make logs
make smoke
make ingest
make retrieval-smoke
make ingress-lifecycle-smoke
make transcription-smoke
make transcribe AUDIO=/path/to/meeting.m4a
make meeting-smoke
make meeting AUDIO=/path/to/meeting.m4a
make meeting-list
make meeting-show ID=mtg_...
make meeting-publish ID=mtg_... ACL=everyone
make diarization-probe AUDIO=/path/to/meeting.m4a
make audit
make metrics
make identity-info
make reset-dev-users
make trust-dev-ca
make down
make config
```

## Security posture of this development slice

This is **not yet a deployable enterprise runtime**.

Current invariants:

1. vLLM, Postgres, Knowledge Service, MongoDB and Keycloak have no direct host ports.
2. Runtime Web, LiteLLM, LibreChat, Prometheus and the Meetings API bind to `127.0.0.1` only in development.
3. Caddy exposes only the local development OIDC issuer on loopback port 8443.
4. LibreChat reaches inference through Knowledge Service then LiteLLM; it cannot reach vLLM directly.
5. OIDC users are gated by the configured runtime user role (`runtime-user` on fresh development installs).
6. Keycloak subjects survive ordinary service restarts; the dev fixture also pins subject UUIDs.
7. Connectors cannot write Postgres directly; they cross an authenticated internal ingestion API.
8. Knowledge reads use a separate query credential; `/internal/retrieve`, document inventory and `/v1/chat/completions` reject caller-supplied identity headers unless the caller first authenticates as an approved query gateway.
9. The query credential presented to Knowledge is replaced with LiteLLM's own credential before forwarding, so LibreChat does not need the LiteLLM master key. Signed/delegated end-user identity remains a production hardening option beyond the current trusted-gateway model.
10. Retrieval ACL filtering occurs in Postgres before chunks are returned to the application/model.
11. Retrieved document text is injected at user-message privilege inside explicit untrusted-context delimiters; the system role contains only trusted handling policy. Existing caller system prompts are augmented rather than preceded by a second RAG system message.
12. Private organisational retrieval and external tool capability are separated deterministically: `/v1/chat/completions` performs ACL-aware retrieval and rejects tool/function capability; `/public/v1/chat/completions` permits tools but performs no organisational retrieval. Prompt-injection detection is not trusted as an egress control.
13. MongoDB requires a least-privilege LibreChat database credential and is reachable only on an internal `librechat-data` network shared with LibreChat. Existing development volumes are upgraded over a loopback-only bootstrap listener before authenticated network startup.
14. Secrets live in `.env` / `.runtime-secrets`, both gitignored. The rendered LiteLLM metrics credential is `0640` (host owner/group only), with Prometheus granted the checkout owner's group rather than making the key world-readable.
15. LiteLLM logging has message/response logging disabled globally; clients cannot opt out of governance audit with `no-log=true`.
16. Audit events are append-only metadata records and carry authenticated user identity without prompt/response content.
17. Prometheus is loopback-only; DCGM and other scrape targets have no host ports.
18. Speaches has no host port; LibreChat is exempted to reach only the exact private `speaches:8000` speech endpoint.
19. Meeting drafts are managed by a separate authenticated Meetings service; publication into Knowledge is explicit and requires an ACL.
20. Runtime Web is a backend-for-frontend: OIDC sessions terminate server-side, internal bearer credentials are never sent to browser JavaScript, mutating browser calls require CSRF validation, and accepted OIDC JWT algorithms are pinned to RS256.
21. Meeting resources created through Runtime Web carry an authenticated owner subject; non-admin users cannot list or fetch another owner's meeting through the BFF.
22. Browser navigation is canonicalized to `WEB_PUBLIC_URL` before OIDC state is created, preventing `127.0.0.1`/`localhost` cookie-origin mismatches in development.
23. Public web search is disabled by default and implemented by a dedicated MCP service on the separate `tooling` network; that service is not attached to the runtime data/inference network.
24. The public-web tool exposes bounded provider search only, uses a fixed provider endpoint, and does not provide arbitrary URL fetching.
25. Public-web egress audit records exclude query and result content.
26. Public-web provider calls have explicit global per-minute/per-hour/per-day budgets to bound shared-key spend and runaway tool loops. Per-user/session accounting remains future work once authenticated identity reaches the MCP boundary.

The `--api-key` setting on vLLM is defence in depth, not its security boundary: the service remains private to the runtime network.

OpenTelemetry remains deferred until we have a useful cross-service trace consumer/use case.

Next: make the reference implementation easy to reproduce and inspect on a clean host, exercise realistic workloads, document backup/restore and production IdP assumptions, and add real connectors only when they improve the reference architecture rather than to satisfy a particular deployment checklist.

## Model swap

Edit `.env`:

```bash
VLLM_MODEL=another/model
VLLM_SERVED_MODEL=local-general
VLLM_REASONING_PARSER=qwen3  # change/disable when the model family changes
```

Keep `VLLM_SERVED_MODEL=local-general`; LiteLLM maps that internal stable name to the public alias `general`.

## Licence

This repository is Apache-2.0. Third-party components/models remain under their own licences; this repository does not relicense them.

## Local meeting workflow

Meeting processing is now a long-running resource service rather than a shell-script-owned workflow. Recording/upload/import mechanisms are clients of the same boundary:

```text
browser recorder / upload / Teams / CLI
                 |
                 v
          Meeting Service
                 |
      STT + diarization + local LLM
                 |
              draft
                 |
             review
                 |
             publish
                 v
          Knowledge Service
```

The development Meetings API is loopback-only on `http://127.0.0.1:8091` and requires a runtime-generated bearer token. Runtime Web is now the normal browser client and keeps that credential server-side; the CLI remains a convenient engineering client:

```bash
MEETING_TITLE="Engineering weekly" \
MEETING_PARTICIPANTS="Alex,Sam" \
MEETING_VOCAB="Kookaburra,vLLM,LiteLLM" \
make meeting AUDIO=/path/to/meeting.m4a
```

`POST /v1/meetings` returns immediately with a meeting resource in `queued` state. The CLI waits by default and downloads the resulting artifacts into `artifacts/meetings/<meeting-id>/`; set `MEETING_WAIT=0` to exercise the asynchronous trigger path. Jobs progress through `queued -> processing -> draft`, with `failed` as the error state. Publication moves a reviewed draft to `published`. The development service intentionally uses one processing worker so simultaneous uploads queue rather than competing for CPU/model resources.

A draft contains:

- `raw_transcript.md` — immutable timestamped ASR evidence;
- `normalized_transcript.md` — conservative normalization only;
- `transcript.md` — compatibility copy of the normalized transcript;
- `normalization.json` — normalization audit;
- `summary.md` — evidence-grounded decisions/actions/open questions;
- `meeting.json` — machine-readable processing record;
- `worker.log` and optional `*.debug.txt` diagnostics.

Useful resource commands:

```bash
make meeting-list
make meeting-show ID=mtg_...
make meeting-publish ID=mtg_... ACL=everyone
# or e.g. ACL='user:<subject>,group:<group-id>'
```

Publication is deliberately separate from processing. The normalized transcript is the canonical evidence document sent through the existing authenticated Knowledge ingress API; the generated summary is not promoted as source evidence. A publish request must supply explicit ACL principals, so creating a meeting draft cannot accidentally make it organisation-wide knowledge.

Audio is retained only while needed for processing by default. `MEETING_RETAIN_AUDIO=1` keeps the uploaded source in the private meeting store for later policy/review experiments.

Diarization labels remain anonymous (`SPEAKER_00`, ...). `MEETING_SPEAKER_MAP` can provide an explicit mapping, and `MEETING_DIARIZE=0`, `MEETING_NORMALIZE=0`, `MEETING_SUMMARY=0`, and `MEETING_REQUIRE_DIARIZATION=1` remain available for controlled experiments.

The summary layer is extraction rather than brainstorming: decisions/actions/open questions must be supported by transcript evidence, and raw ASR is preserved separately even when normalization succeeds.

## Why Yossarian?

The name is a nod to Joseph Heller's *Catch-22*: sometimes apparent paranoia is simply an accurate reading of the system. This project tries to make the corresponding engineering move — treat trust boundaries explicitly rather than optimistically.
