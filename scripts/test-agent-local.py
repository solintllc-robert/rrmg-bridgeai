#!/usr/bin/env python3
"""Run the agent's entrypoint locally against the deployed gateway.

Exercises everything except the AgentCore Runtime wrapper itself: the prompt is
handled by the same code that will run in the cloud, the tools come from the
real ACGW-MCP, and the token is a real Cognito token.

  ./scripts/test-agent-local.py admin "What is Dana Whitfield's home address?"

Several prompts run as one conversation, which is how to see whether the agent
is remembering:

  ./scripts/test-agent-local.py admin "Look up Dana Whitfield" "Where does she live?"
"""

import os
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def terraform_output(name, required=True):
    result = subprocess.run(
        ["terraform", "output", "-raw", name],
        cwd=ROOT / "terraform",
        capture_output=True,
        text=True,
        check=required,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def get_token(who):
    return subprocess.run(
        [str(ROOT / "scripts" / "get-token.sh"), who],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


class FakeContext:
    """Stands in for the runtime context object, which carries the headers."""

    def __init__(self, token, session_id):
        self.request_headers = {"Authorization": f"Bearer {token}"}
        self.session_id = session_id


def main():
    who = sys.argv[1] if len(sys.argv) > 1 else "admin"
    prompts = sys.argv[2:] or ["What is Dana Whitfield's home address?"]

    # Only fall back to the shared profile when the environment has no
    # credentials of its own; that profile is not configured on every machine.
    if not os.environ.get("AWS_ACCESS_KEY_ID"):
        os.environ.setdefault("AWS_PROFILE", "solint-standard")
    os.environ["ACGW_MCP_URL"] = terraform_output("acgw_mcp_url")

    # Not required: before the memory store is applied there is no such output,
    # and the agent is written to answer without one.
    memory_id = terraform_output("agent_memory_id", required=False)
    if memory_id:
        os.environ["AGENT_MEMORY_ID"] = memory_id
    else:
        print("--- no memory store deployed; each turn will start fresh")

    sys.path.insert(0, str(ROOT / "agent"))
    import main as agent_main  # noqa: E402  (import after env is set)

    token = get_token(who)
    # One id for every turn below, so they land in the same stored conversation.
    conversation = f"local-{uuid.uuid4().hex}"

    print(f"--- user: {who}")
    print(f"--- conversation: {conversation}")

    context = FakeContext(token, conversation)
    for prompt in prompts:
        print(f"\n--- prompt: {prompt}\n")
        result = agent_main.invoke(
            {"prompt": prompt, "conversation_id": conversation}, context
        )
        print(result["result"])


if __name__ == "__main__":
    main()
