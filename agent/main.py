"""Customer directory agent.

Runs on AgentCore Runtime. The runtime validates the caller's Cognito token
before this code executes, then passes the token through in the Authorization
header. The agent reuses that same token to reach the tools gateway, so the
end user's identity travels all the way to the point where authorization is
decided rather than stopping at the front door.

The agent deliberately holds no credentials of its own for reaching customer
data. If the caller may not see something, the gateway refuses the tool call
and the agent simply reports that.

Conversation history lives in AgentCore Memory, partitioned by the caller's
subject claim and by the groups their token carried, so that a transcript can
only ever be replayed to the person who produced it while they still hold the
entitlement they produced it under. See _memory_session below and memory.tf.
"""

import hashlib
import logging
import os
import re

from bedrock_agentcore.memory.integrations.strands.config import AgentCoreMemoryConfig
from bedrock_agentcore.memory.integrations.strands.session_manager import (
    AgentCoreMemorySessionManager,
)
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from botocore.exceptions import ClientError
from mcp.client.streamable_http import streamablehttp_client
from strands import Agent
from strands.agent.conversation_manager import SummarizingConversationManager
from strands.models import BedrockModel
from strands.tools.mcp import MCPClient
from strands.types.exceptions import MCPClientInitializationError, ModelThrottledException

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("customer-directory-agent")

GATEWAY_URL = os.environ["ACGW_MCP_URL"]
MODEL_ID = os.environ.get("AGENT_MODEL_ID", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")

# Absent, the agent still answers - it just does not remember anything.
MEMORY_ID = os.environ.get("AGENT_MEMORY_ID")
REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")

# Conversation ids arrive from the caller, so they are checked before being used
# to name a memory partition rather than trusted as given.
CONVERSATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")

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
- A conversation may run over several questions, and you can see the earlier
  ones. Use them to work out who is being discussed, so that a follow-up like
  "and her work address?" is answered about the customer already established
  rather than asked about again. Values themselves still come from the tools:
  if an earlier turn never retrieved something, look it up now.

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
    """Read the claims out of an already-validated token.

    The runtime verified this token's signature before invoking us, which is
    what makes reading it without verifying it again reasonable. There is no
    signature check here and there must not be one relied upon.

    Two callers, and the difference between them matters. _diagnostic uses this
    only to report who arrived. _memory_session uses it to decide which stored
    conversation this caller may see, which is a real access decision - taken
    here because the alternative is trusting the request body, and a caller who
    could name their own subject could name somebody else's.

    What is still not decided here: whether the caller may see any customer
    data. That remains the gateway's to answer, per tool call.
    """
    import base64
    import json

    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def _conversation_id(payload, context):
    """Decide which conversation this turn belongs to.

    Read from the request body rather than the runtime's session id, because
    the body is the one thing certain to survive the hop through ACGW-API: the
    runtime forwards only the headers on its allowlist, and the session id
    header is consumed by the runtime itself rather than passed along. The
    session id is still used where it is there, which covers callers that do
    not send one in the body.

    A turn with no usable id is answered and then forgotten, rather than filed
    under some shared default where it would sit alongside somebody else's.
    """
    candidate = None

    if isinstance(payload, dict):
        for key in ("conversation_id", "conversationId"):
            value = payload.get(key)
            if isinstance(value, str) and value.strip():
                candidate = value.strip()
                break

    if candidate is None:
        candidate = getattr(context, "session_id", None)

    if not candidate or not CONVERSATION_ID.match(candidate):
        return None

    return candidate


def _memory_session(token, conversation_id):
    """Give the agent the history of this conversation, and only this one.

    Both ids decide who can read what, so neither is taken from the request.

    ``actor_id`` is the caller's subject claim, out of the token the runtime has
    already validated. A caller able to name their own actor id could name
    somebody else's and read that person's conversations.

    ``session_id`` carries the entitlement the conversation was held under. The
    gateway decides who may see a home address from the group in the caller's
    token, and decides it per call; history replayed out of memory arrives
    without that decision being taken again. So a transcript recorded while
    somebody held customer-admin must not follow them out of the group. Mixing
    the group list into the session id means losing a group starts a fresh
    conversation instead of inheriting the previous one's contents.
    """
    claims = _claims(token)

    subject = claims.get("sub")
    if not subject:
        logger.warning("token carries no subject claim; this turn will not be remembered")
        return None

    groups = claims.get("cognito:groups") or []
    if isinstance(groups, str):
        groups = [groups]
    entitlement = hashlib.sha256("\x00".join(sorted(groups)).encode()).hexdigest()[:12]

    config = AgentCoreMemoryConfig(
        memory_id=MEMORY_ID,
        actor_id=subject,
        session_id=f"{conversation_id}-{entitlement}",
        # Restored turns carry what the assistant said, not the raw tool
        # payloads behind it. The sentence the user already read is what makes
        # their next question answerable; replaying the payloads as well would
        # spend tokens restating what the sentence already contains.
        filter_restored_tool_context=True,
    )

    return AgentCoreMemorySessionManager(config, region_name=REGION)


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


def _explain_failure(error):
    """Translate a failure into a sentence worth showing to a person.

    Dispatch on the exception type, and for AWS calls on the error code, which
    is part of the API contract. The message text is only ever used to tell two
    conditions apart that share a code - AWS is free to reword it, and a
    rewording must not quietly demote a known failure to the catch-all below.
    """
    # The event loop wraps whatever the model provider raised.
    cause = getattr(error, "original_exception", error)

    if isinstance(cause, ModelThrottledException):
        # Two very different conditions share this exception. A per-minute
        # limit clears on its own in seconds; a daily allowance of zero never
        # does, and telling someone to try again shortly would be false.
        if "per day" in str(cause):
            return (
                "I can reach the customer directory, but this AWS account has no "
                "language model capacity allocated, so I cannot compose an answer. "
                "Its daily token allowance is zero for every model, which is not "
                "something that clears with time or by choosing a different model. "
                "It needs an AWS support request to raise the Bedrock quota."
            )
        return (
            "The language model is busy right now. Please try again in a few "
            "moments."
        )

    if isinstance(cause, MCPClientInitializationError):
        return (
            "I could not reach the customer directory, so I have nothing to "
            "answer from. That is a fault on our side, not something you did."
        )

    if isinstance(cause, ClientError):
        code = cause.response.get("Error", {}).get("Code", "")

        # A one-time account setup step: Bedrock reports missing model access
        # as a plain ResourceNotFoundException, which other missing resources
        # also use, so here the message is the tiebreak rather than the signal.
        if code == "ResourceNotFoundException" and "use case details" in str(cause):
            return (
                "I can reach the customer directory, but I have no language model "
                "available to answer with. This account has not completed Bedrock's "
                "model access form for Anthropic models. Someone with access to the "
                "AWS console needs to submit it under Bedrock, Model access."
            )

        if code in ("AccessDeniedException", "AccessDenied"):
            # This is the agent's own role being refused, never the caller's.
            # A gateway refusal comes back as a tool result and is answered by
            # the model under SYSTEM_PROMPT; it never surfaces as an exception
            # here, so this must not be worded as a limit on the user.
            return (
                "I am not permitted to use the language model I need to answer "
                "that. That is a configuration fault on our side, not a limit on "
                "what you are allowed to see."
            )

    # Anything unrecognised: say so plainly rather than pretending to answer.
    return f"Something went wrong while answering that, and I could not recover: {error}"


@app.entrypoint
def invoke(payload, context):
    token = _bearer_token(context)

    # A diagnostic request checks the identity chain without invoking a model.
    if isinstance(payload, dict) and payload.get("diagnostic"):
        return _diagnostic(token)

    prompt = _extract_prompt(payload)

    # Memory is an improvement to the answer, not a condition of giving one, so
    # a failure here degrades the agent to a forgetful one rather than a broken
    # one. Logged at error level with the traceback, because the difference is
    # otherwise invisible from the outside - the agent keeps answering, just
    # never remembering.
    session_manager = None
    conversation_id = _conversation_id(payload, context)
    if MEMORY_ID and conversation_id:
        try:
            session_manager = _memory_session(token, conversation_id)
        except Exception:
            logger.exception("could not open conversation memory; answering without history")

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
        try:
            tools = gateway.list_tools_sync()
            logger.info("gateway exposed %d tools", len(tools))

            agent = Agent(
                model=model,
                tools=tools,
                system_prompt=SYSTEM_PROMPT,
                session_manager=session_manager,
                # Reactive only: this does nothing until the conversation
                # threatens to outgrow the context window, at which point it
                # summarises the oldest turns rather than dropping them. A
                # plain sliding window would be cheaper but would discard the
                # customer id resolved several turns ago, which is exactly the
                # thing the user is still referring to as "her".
                conversation_manager=SummarizingConversationManager(),
            )
            return {"result": str(agent(prompt))}
        except Exception as error:
            # A bare 500 and a suggestion to read server logs is no use to the
            # person who just asked a question, so every failure from here on
            # leaves as a sentence instead - reaching the gateway included.
            logger.exception("agent invocation failed")
            return {"result": _explain_failure(error)}


if __name__ == "__main__":
    app.run()
