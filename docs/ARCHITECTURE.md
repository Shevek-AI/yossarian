# Architecture

Yossarian is a small reference composition rather than a new model server or chat framework. Components are intentionally replaceable behind narrow boundaries.

## Core paths

### Private organisational knowledge

```text
LibreChat / Runtime Web
  -> authenticated Knowledge query boundary
  -> SQL ACL filter + vector ranking
  -> untrusted retrieved context
  -> LiteLLM
  -> vLLM
  -> local model
```

This path does not permit tool/function capability.

### Public/general local AI

```text
LibreChat
  -> authenticated public chat boundary (no organisational retrieval)
  -> LiteLLM
  -> vLLM
  -> local model
       |
       +-> optional Public Web Search MCP
```

Public Web Search is disabled by default and runs on a separate network.

### Ingest

```text
source connector
  -> canonical document + provenance + ACL
  -> authenticated ingress API
  -> chunk/embed/index
  -> Postgres + pgvector
```

Connectors never write the retrieval database directly.

### Meetings

```text
audio trigger
  -> Meeting Service
  -> local STT + diarisation
  -> conservative normalization
  -> evidence-grounded summary
  -> draft/review
  -> explicit ACL publication
  -> canonical Knowledge ingress
```

The normalized transcript is evidence; the generated summary remains derived data.

## Networks

- `runtime`: inference, identity, knowledge, meetings, observability and trusted gateways.
- `tooling`: external-tool bridge; Public Web Search lives here and cannot route directly to runtime data services.
- `librechat-data`: internal-only LibreChat/MongoDB network.

The current Compose topology is meant to make these boundaries inspectable. It is not a claim that Docker Compose is the right production orchestrator at every scale.

## Identity

Development uses Keycloak through local Caddy TLS. Production should normally point at the organisation's existing OIDC provider and map its users/groups into canonical ACL principals.

Development installs use neutral `runtime-user` / `runtime-admin` roles. Internal protocol and role identifiers are intentionally generic rather than product-branded.

## Deployment profiles

### Offline/local

- local inference;
- private knowledge;
- meetings;
- audit/metrics;
- `WEB_SEARCH_ENABLED=0`.

### Controlled egress

Same as above, plus explicitly enabled Public Web Search. Search queries leave the environment for the configured provider.
