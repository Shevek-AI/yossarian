.PHONY: bootstrap up smoke status logs down config ui web web-smoke web-search-smoke security-smoke identity-info trust-dev-ca audit metrics ingest retrieval-smoke ingress-lifecycle-smoke transcription-smoke transcribe meeting meeting-smoke meeting-list meeting-show meeting-publish diarization-probe speech-models reset-dev-users

bootstrap:
	./scripts/bootstrap.sh

up:
	./scripts/up.sh

smoke:
	./scripts/smoke.sh

status:
	./scripts/status.sh

logs:
	docker compose logs -f --tail=200

down:
	./scripts/down.sh

config:
	docker compose config

ui:
	@echo "http://localhost:$${LIBRECHAT_HOST_PORT:-3080}"

web:
	@echo "http://localhost:$${WEB_HOST_PORT:-8080}"

web-smoke:
	./scripts/web-smoke.sh

web-search-smoke:
	./scripts/web-search-smoke.sh

security-smoke:
	./scripts/security-smoke.sh

identity-info:
	./scripts/identity-info.sh

trust-dev-ca:
	./scripts/trust-dev-ca.sh


audit:
	./scripts/audit.sh

metrics:
	@echo "http://localhost:$${PROMETHEUS_HOST_PORT:-9090}"

ingest:
	./scripts/ingest.sh

retrieval-smoke:
	./scripts/retrieval-smoke.sh

ingress-lifecycle-smoke:
	./scripts/ingress-lifecycle-smoke.sh

transcription-smoke:
	./scripts/transcription-smoke.sh

transcribe:
	@test -n "$(AUDIO)" || { echo "usage: make transcribe AUDIO=/path/to/meeting.m4a" >&2; exit 2; }
	./scripts/transcribe.sh "$(AUDIO)"

meeting:
	@test -n "$(AUDIO)" || { echo "usage: make meeting AUDIO=/path/to/meeting.m4a" >&2; exit 2; }
	./scripts/meeting.sh "$(AUDIO)"

meeting-smoke:
	./scripts/meeting-smoke.sh

meeting-list:
	./scripts/meeting-list.sh

meeting-show:
	@test -n "$(ID)" || { echo "usage: make meeting-show ID=mtg_..." >&2; exit 2; }
	./scripts/meeting-show.sh "$(ID)"

meeting-publish:
	@test -n "$(ID)" || { echo "usage: make meeting-publish ID=mtg_... ACL=everyone" >&2; exit 2; }
	@test -n "$(ACL)" || { echo "usage: make meeting-publish ID=mtg_... ACL=everyone" >&2; exit 2; }
	./scripts/meeting-publish.sh "$(ID)" "$(ACL)"

diarization-probe:
	@test -n "$(AUDIO)" || { echo "usage: make diarization-probe AUDIO=/path/to/meeting.m4a" >&2; exit 2; }
	./scripts/diarization-probe.sh "$(AUDIO)"

speech-models:
	./scripts/ensure-speech-models.sh

reset-dev-users:
	./scripts/reset-dev-users.sh
