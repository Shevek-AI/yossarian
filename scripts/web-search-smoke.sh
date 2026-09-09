#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Run the protocol smoke from inside the private web-search container; the MCP
# service has deliberately no host port.
docker compose exec -T web-search python - <<'PY'
import asyncio
import json
import urllib.request

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

health = json.load(urllib.request.urlopen("http://127.0.0.1:8092/health", timeout=3))
assert health["ok"] is True, health
assert health["state"] in {"disabled", "enabled", "misconfigured"}, health
assert health["arbitrary_url_fetch"] is False, health
budget = health.get("request_budget") or {}
assert int(budget.get("per_minute", 0)) > 0, health
assert int(budget.get("per_hour", 0)) >= int(budget["per_minute"]), health
assert int(budget.get("per_day", 0)) >= int(budget["per_hour"]), health
print("Web-search health:", json.dumps(health, sort_keys=True))

async def main():
    async with streamablehttp_client("http://127.0.0.1:8092/mcp") as (read, write, _get_session_id):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            names = [tool.name for tool in tools.tools]
            assert "search_public_web" in names, names
            print("MCP tools:", ", ".join(names))

asyncio.run(main())
PY


# The MCP boundary can be healthy while the inference server still rejects
# LibreChat's OpenAI `tool_choice=auto`. Exercise that exact contract without
# calling the external search provider.
echo "Checking local model accepts OpenAI auto tool choice"
docker compose exec -T knowledge python3 - <<'PY'
import json
import os
import urllib.request

payload = {
    "model": "general",
    "messages": [
        {
            "role": "user",
            "content": "Do not call any tool. Reply exactly: auto tool choice ready",
        }
    ],
    "tools": [
        {
            "type": "function",
            "function": {
                "name": "noop",
                "description": "A smoke-test tool that must not be executed.",
                "parameters": {"type": "object", "properties": {}},
            },
        }
    ],
    "tool_choice": "auto",
    "temperature": 0,
    "max_tokens": 128,
    "chat_template_kwargs": {"enable_thinking": False},
}
request = urllib.request.Request(
    "http://127.0.0.1:8090/public/v1/chat/completions",
    data=json.dumps(payload).encode(),
    headers={
        "Authorization": f"Bearer {os.environ['KNOWLEDGE_QUERY_TOKEN']}",
        "Content-Type": "application/json",
        "X-Runtime-User-ID": "web-search-smoke",
        "X-Runtime-Subject": "11111111-1111-4111-8111-111111111111",
        "X-Runtime-Client": "web-search-smoke",
    },
    method="POST",
)
with urllib.request.urlopen(request, timeout=120) as response:
    body = json.load(response)
assert body.get("choices"), body
print("General AI auto-tool request: PASS")
PY

echo "Web search MCP smoke: PASS"
echo "Policy note: this smoke does not send a query to the external provider."
