"""Customer directory agent.

Runs on AgentCore Runtime. The runtime validates the caller's Cognito token
before this code executes, then passes the token through in the Authorization
header. The agent reuses that same token to reach the tools gateway, so the
end user's identity travels all the way to the point where authorization is
decided rather than stopping at the front door.

The agent deliberately holds no credentials of its own for reaching customer
data. If the caller may not see something, the gateway refuses the tool call
and the agent simply reports that.
"""

import logging
import os

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from mcp.client.streamable_http import streamablehttp_client
from strands import Agent
from strands.models import BedrockModel
from strands.tools.mcp import MCPClient

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("customer-directory-agent")

GATEWAY_URL = os.environ["ACGW_MCP_URL"]
MODEL_ID = os.environ.get("AGENT_MODEL_ID", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")

SYSTEM_PROMPT = """\
You are a customer directory assistant. You answer questions about customers
using only the tools provided to you.

How to work:
- Customers are identified by an id such as C-1001. When the user names a
  person instead, search the directory first to find their id, then use that
  id with the other tools.
- Answer only from what the tools return. Never guess a value, and never fill
  in an address, phone number, or company from your own knowledge.
- If a search returns several people, list the matches and ask which one is
  meant rather than picking one.
- If a search returns nobody, say so plainly.

About permissions:
- Some information is restricted, and whether you may see it depends on who is
  asking. That decision is not yours to make and not yours to work around.
- If a tool call comes back refused or unauthorized, tell the user plainly that
  they are not authorized to see that particular information, and offer what
  you can retrieve instead. Do not retry the same call, do not look for another
  tool to get the same value, and do not infer the answer from anything else.

Keep answers short and factual. Give the information asked for without padding.
"""


app = BedrockAgentCoreApp()


def _bearer_token(context):
    """Pull the caller's bearer token out of the inbound request headers.

    The runtime only forwards headers that are on the allowlist configured on
    the runtime resource; Authorization is there for exactly this reason.
    """
    headers = getattr(context, "request_headers", None) or {}
    value = None
    for key in ("Authorization", "authorization"):
        if key in headers:
            value = headers[key]
            break

    if not value:
        raise RuntimeError(
            "No Authorization header reached the agent. Check that the runtime's "
            "request header allowlist includes Authorization."
        )

    return value[7:].strip() if value.lower().startswith("bearer ") else value.strip()


def _extract_prompt(payload):
    if isinstance(payload, str):
        return payload
    if isinstance(payload, dict):
        for key in ("prompt", "input", "message", "question"):
            value = payload.get(key)
            if isinstance(value, str) and value.strip():
                return value
            # Accept {"input": {"prompt": "..."}} as well.
            if isinstance(value, dict):
                nested = value.get("prompt") or value.get("message")
                if isinstance(nested, str) and nested.strip():
                    return nested
    raise ValueError("No prompt found in the request payload.")


def _claims(token):
    """Read claims from an already-validated token, for diagnostics only.

    The runtime verified this token's signature before invoking us, so this
    decode is purely to report who the caller is. Nothing is authorized on the
    basis of what this returns.
    """
    import base64
    import json

    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def _diagnostic(token):
    """Report the identity that arrived and the tools it can reach.

    Exercises the full chain - token forwarded from the runtime, gateway
    accepting it, tools listed - without calling the model. Useful on its own
    for checking connectivity, and the only way to verify the chain while
    model access is pending.
    """
    claims = _claims(token)
    gateway = MCPClient(
        lambda: streamablehttp_client(GATEWAY_URL, headers={"Authorization": f"Bearer {token}"})
    )
    with gateway:
        tools = sorted(tool.tool_name for tool in gateway.list_tools_sync())

    return {
        "result": {
            "mode": "diagnostic",
            "caller": {
                "subject": claims.get("sub"),
                "groups": claims.get("cognito:groups", []),
                "client_id": claims.get("client_id"),
                "issuer": claims.get("iss"),
            },
            "gateway_url": GATEWAY_URL,
            "tools_visible": tools,
        }
    }


@app.entrypoint
def invoke(payload, context):
    token = _bearer_token(context)

    # A diagnostic request checks the identity chain without invoking a model.
    if isinstance(payload, dict) and payload.get("diagnostic"):
        return _diagnostic(token)

    prompt = _extract_prompt(payload)

    # The user's own token is what opens the gateway. The agent has no
    # separate credential for customer data.
    gateway = MCPClient(
        lambda: streamablehttp_client(
            GATEWAY_URL,
            headers={"Authorization": f"Bearer {token}"},
        )
    )

    model = BedrockModel(model_id=MODEL_ID)

    with gateway:
        tools = gateway.list_tools_sync()
        logger.info("gateway exposed %d tools", len(tools))

        agent = Agent(model=model, tools=tools, system_prompt=SYSTEM_PROMPT)
        result = agent(prompt)

    return {"result": str(result)}


if __name__ == "__main__":
    app.run()
