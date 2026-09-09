# Reference implementation build sequence

Build one narrow, testable security boundary at a time. The roadmap records the engineering path of the open-source reference implementation; it is not a deployment commitment or product checklist.

## Slice 0 — inference path ✅

`curl -> LiteLLM -> vLLM -> local model`

Acceptance:
- vLLM is not bound to a host port.
- LiteLLM is bound only to `127.0.0.1` in development.
- LiteLLM exposes the stable northbound model alias `general`.
- A real completion succeeds on the local GPU.
- Compose does not start LiteLLM until vLLM is healthy.

## Slice 1 — human UI ✅

`browser -> LibreChat -> LiteLLM -> vLLM`

Development choices:
- LibreChat is a replaceable UI profile, not part of the runtime contract.
- MongoDB exists only because LibreChat requires it.
- MongoDB remains private to the Compose network.

## Slice 2 — identity ✅ development vertical slice

`browser -> LibreChat -> OIDC -> Caddy(local TLS) -> Keycloak`

Development choices:
- Keycloak is only a stand-in for a organisation's IdP.
- OIDC users require the `runtime-user` realm role.
- Test-user subject UUIDs are fixed and Keycloak state persists ordinary restarts.
- Dev login rate limits are permissive while auth is being exercised.

Production acceptance still to do:
- local password login disabled completely;
- organisation OIDC issuer rather than bundled Keycloak;
- explicit downstream identity delegation rather than trusting plain internal headers;
- production TLS and DNS.

## Slice 3 — audit + machine observability ✅ development vertical slice

`authenticated request -> identity metadata -> LiteLLM -> append-only content-free audit`

`Prometheus <- vLLM / LiteLLM / Keycloak / NVIDIA DCGM`

Acceptance:
- prompt/response bodies are not copied into audit events;
- authenticated identity reaches the audit layer;
- Prometheus scrapes inference, gateway, identity and GPU telemetry.

## Slice 4 — permission-aware retrieval ✅ development vertical slice

`LibreChat -> Knowledge Service -> Postgres/pgvector -> LiteLLM`

Development baseline:
- one synthetic corpus under `fixtures/knowledge`;
- dense embeddings with FastEmbed `BAAI/bge-small-en-v1.5`;
- Postgres + pgvector;
- canonical ACL principals (`everyone`, `user:<sub>`, future `group:<id>`);
- authenticated email/subject propagated from LibreChat;
- a dedicated knowledge-query credential authenticates the trusted LibreChat/Web gateways before their subject/group assertions are accepted;
- retrieval context is kept at user-message privilege inside explicit untrusted-data delimiters; the system role contains only trusted handling policy.

Critical acceptance test:
- engineering can retrieve engineering + public, never finance;
- finance can retrieve finance + public, never engineering;
- ordinary staff can retrieve public only;
- **ACL filtering occurs in SQL before similarity-ranked chunks leave Postgres**.

## Slice 5 — explicit document ingress ✅ development vertical slice

`local connector -> canonical source sync -> Knowledge Service -> Postgres/pgvector`

Acceptance:
- knowledge startup does not implicitly ingest fixture content;
- connectors cannot write Postgres directly;
- ingestion API requires a runtime-generated credential;
- canonical records carry provenance and ACL principals;
- ACL-only updates do not require re-embedding unchanged content;
- full source sync propagates source deletion into the index;
- query ACL remains enforced in SQL before ranking results leave Postgres.

Example ingress work beyond the reference core:
- Microsoft Graph/SharePoint connector with source ACL/group import;
- organisation Entra identity/group reconciliation;
- delta cursors/checkpoints and measurable permission-change propagation.

Still source-agnostic:
- text extraction for PDF/DOCX/HTML behind the connector contract.

Next retrieval work:
- benchmark dense-only against lexical/hybrid retrieval before adding BM25/RRF/reranking;
- optionally replace the current authenticated trusted-gateway identity assertion with signed/delegated end-user identity for production defence in depth;
- add retrieval metadata to audit/trace without logging document contents by default.

## Slice 6 — transcription ✅ development vertical slice

`Meetings / explicit host helper -> Speaches/faster-whisper -> local transcript`

Development choices:
- OpenAI-compatible Speaches endpoint;
- CPU/int8 by default so speech cannot starve vLLM of GPU memory;
- speech service remains private to the Compose network;
- LibreChat knows about the private Speaches endpoint and exempts only the exact `speaches:8000` address from its private-address STT guard, but composer STT is disabled by default on the pinned v0.8.7 because of upstream issue #14726;
- tracked WAV fixture plus arbitrary-file `make transcribe AUDIO=...` helper;
- TTS deferred.

Acceptance:
- local fixture transcription contains expected words;
- no cloud speech API is required;
- arbitrary meeting audio can be transcribed from the host without publishing a speech port.

Next speech work:
- benchmark small/medium/large-v3-turbo class models on real meeting audio;
- decide GPU sharing only from measured latency/VRAM;
- add content-free speech audit metadata at the governed edge rather than logging transcript/audio bodies.


## Slice 7 — trustworthy meeting memory 🧪 development vertical slice

`meeting trigger -> async Meetings service -> local STT/diarization/summary -> draft -> review -> explicit Knowledge publication`

Development choices:
- startup provisions every model required by enabled speech capabilities (STT + diarization segmentation + speaker embedding) into the persistent Speaches cache;
- meeting processing is owned by a long-running authenticated resource service; CLI/upload/recording/integration triggers are clients rather than architecture;
- jobs have persistent `queued -> processing -> draft -> published` state, with failed-job recovery after service restart;
- one development worker serializes heavy meeting jobs rather than creating accidental CPU/model contention;
- source audio is kept only while processing by default and may be retained explicitly by policy;
- Whisper receives explicit participant/vocabulary context as prompt/hotwords;
- raw ASR remains immutable evidence; a separate normalization pass may only replace exact ASR spans with caller-provided participant/vocabulary terms, with every change recorded;
- diarization uses Speaches' local `/v1/audio/diarization` endpoint when available and degrades to timestamp-only transcript unless explicitly required;
- ASR segments are assigned to diarization turns by maximum temporal overlap;
- speaker identities are not guessed: optional `SPEAKER_XX=Name` mapping is supplied explicitly by the user;
- long transcripts are summarised hierarchically so the 8k local model context is not silently exceeded;
- summary extraction uses structured evidence records and code-rendered Markdown: decisions/actions/open questions cannot be invented as useful follow-ups;
- meeting normalization/summary calls use LiteLLM and therefore inherit the existing content-free inference audit;
- generated meeting artifacts are stored privately by the service; the development CLI downloads reviewed copies into a gitignored local directory;
- draft publication requires an explicit ACL and crosses the existing authenticated canonical Knowledge ingress boundary;
- the normalized transcript, not the generated summary, is the published evidence source.

Acceptance to exercise on real recordings:
- multi-speaker test recording produces a timestamped transcript;
- diarization distinguishes speakers well enough to support meeting notes;
- known participant names such as Alex/Sam/Jordan improve when supplied as participant/vocabulary context;
- raw and normalized transcripts are separately reviewable and every normalization is auditable;
- summary contains only supported key points/decisions/actions/open questions with timestamps/speakers where available;
- no cloud speech or summary service is required.

Next meeting work:
- benchmark diarization quality/CPU cost on real 30–60 minute meetings;
- Speaches rc.3 currently exposes no `num_speakers`/`min_speakers`/`max_speakers` controls, so do not fake an expected-speaker-count knob; revisit when the endpoint supports it;
- add a tiny speaker-label review/mapping loop rather than inferring identities;
- exercise the review/publish UX on real meetings and decide the production audio-retention policy;
- exercise the authenticated browser review/publish UX on real meetings and use observed friction to drive the next iteration;
- keep the meeting service source-agnostic so other systems can consume published meeting evidence without product-specific coupling.

## Slice 8 — Runtime Web ✅ development vertical slice

`browser -> Runtime Web/BFF -> Meetings / Knowledge / Governance`

Development choices:
- OIDC terminates in the server-side BFF; browser JavaScript never receives internal service bearer tokens;
- session mutations require CSRF validation;
- meeting ownership is derived from the authenticated OIDC subject;
- ordinary users see only their own meeting resources, while `runtime-admin` can inspect the development runtime;
- browser UX supports meeting upload and direct microphone recording without changing the Meetings service contract;
- draft review/publish remains explicit and defaults to `Private to me` or `Everyone`;
- Knowledge shows only documents whose ACL intersects the authenticated principal set;
- Governance surfaces service readiness, installed model inventory and content-free audit metadata;
- LibreChat remains the replaceable chat client rather than reimplementing chat.

Acceptance:
- unauthenticated API calls are rejected;
- sign-in uses the same Keycloak/OIDC `runtime-user` gate;
- the existing persistent development realm is upgraded idempotently with a separate web OIDC client;
- upload/record -> asynchronous meeting -> review -> publish can be completed from the browser;
- private publication is retrievable only by the publishing OIDC subject;
- internal Meetings/Knowledge/LiteLLM/Speaches credentials are absent from browser responses/static assets.

Production work still to do:
- put the web front door behind production TLS/DNS;
- use the organisation's IdP and explicit group/role mapping;
- decide the production admin authorization model;
- stop exposing the development Meetings/LiteLLM/LibreChat ports on host loopback.

## Slice 9 — controlled egress and web search ✅ development vertical slice

`LibreChat -> private MCP search service -> configured public search provider`

Development choices:
- public-web search is disabled by default;
- enabling it requires both an explicit runtime flag and provider credential;
- the search service joins a separate `tooling` network and has no direct path to runtime data/inference services;
- the tool exposes bounded search-result metadata/snippets only, not arbitrary URL fetch;
- public-web search data is labelled untrusted external content rather than organisational evidence;
- organisational retrieval and external-tool capability are split across separate chat routes: `Private Knowledge` performs ACL-aware retrieval and refuses tools; `General AI` permits tools but performs no organisational retrieval;
- prompt-injection detection at ingest is explicitly **not** treated as a security boundary;
- egress audit events contain provider/status/count/duration but not query or result text;
- shared-provider spend is bounded by configurable global per-minute/per-hour/per-day request budgets;
- alternate `127.0.0.1` browser navigation is canonicalized to `WEB_PUBLIC_URL` before OIDC state is created.

Acceptance:
- disabled state is healthy and discoverable without performing egress;
- MCP initialize/list-tools succeeds on the private network;
- LibreChat can discover the public-web tool;
- a configured deployment can perform a bounded provider search;
- no arbitrary result URL can be supplied to the service for fetching;
- using `127.0.0.1` for the web front door redirects to the canonical origin rather than producing an OIDC state failure.

Production work still to do:
- formal outbound network allow-list/firewall policy in the deployment profile;
- decide whether the supported provider is hosted search, organisation-operated search, or both;
- add an egress-policy verification command that proves actual network reachability matches configuration;
- propagate authenticated end-user/session identity into MCP if per-user rather than global provider budgets become necessary.

## Security hardening checkpoint ✅

Fresh-eyes review fixes folded into the development baseline:
- removed unauthenticated `/debug/retrieve`; query/document/chat reads now require a dedicated knowledge-query credential before identity headers are trusted;
- bearer-token checks use constant-time comparison;
- Web pins accepted OIDC JWTs to RS256 rather than adopting the token header's algorithm;
- MongoDB is authenticated and isolated on a LibreChat-only internal network, including non-destructive upgrade of existing dev volumes;
- RAG document text is no longer inserted as a system-role message;
- public-web shared-key spend is capped globally per minute/hour/day;
- the rendered Prometheus/LiteLLM credential is no longer world-readable;
- `make security-smoke` exercises the main regression boundaries.

## Reference release checkpoint ✅ v0.1.0

- public/project naming is **Yossarian**; internal protocol and role identifiers remain deliberately generic (`runtime-*`);
- README/architecture/threat-model documentation now frame the repository as an open-source reference implementation rather than a vendor-specific product;
- chat is split into `Private Knowledge` (ACL retrieval, no tools) and `General AI` (no organisational retrieval, tools allowed);
- Runtime Web exposes that split as an explicit chat capability choice and LibreChat uses the same endpoint names, with Private Knowledge presented as the recommended default;
- Keycloak realm imports use a generated dedicated import directory rather than individual files inside the persistent data volume, avoiding stale import-file artifacts across realm/name changes;
- prompt-injection detection at ingest is explicitly not trusted as an enforcement control;
- `make security-smoke` checks the private-knowledge/tool separation invariant.

## Slice 10 — reference release / deployment hardening

- production profile and single TLS front door;
- secret lifecycle and rotation;
- pinned/certified image/model release manifest;
- backup/restore and upgrade tests;
- SBOM/dependency/security scanning;
- operator runbook, deployment docs and end-user training material.


## Meeting debugging

- Set `MEETING_DEBUG_LLM_RESPONSES=1` to preserve and print a raw local-LLM response only when structured meeting JSON parsing fails. Debug artifacts can contain transcript-derived content and are off by default.
