# Security

Yossarian is an open-source reference implementation, not a certified production appliance.

Please report suspected vulnerabilities privately to the repository maintainers using the hosting platform's private vulnerability-reporting mechanism when available. Avoid opening a public issue that includes exploit details, credentials, private data, or deployment or organisation information.

The current trust assumptions, prompt-injection model, egress boundaries and known gaps are documented in [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md). Run `make security-smoke` after security-sensitive changes.
