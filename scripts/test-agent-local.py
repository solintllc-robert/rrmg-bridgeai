#!/usr/bin/env python3
"""Run the agent's entrypoint locally against the deployed gateway.

Exercises everything except the AgentCore Runtime wrapper itself: the prompt is
handled by the same code that will run in the cloud, the tools come from the
real ACGW-MCP, and the token is a real Cognito token.

  ./scripts/test-agent-local.py admin "What is Dana Whitfield's home address?"
"""

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def terraform_output(name):
    return subprocess.run(
        ["terraform", "output", "-raw", name],
        cwd=ROOT / "terraform",
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


def get_token(who):
    return subprocess.run(
        [str(ROOT / "scripts" / "get-token.sh"), who],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


class FakeContext:
    """Stands in for the runtime context object, which carries the headers."""

    def __init__(self, token):
        self.request_headers = {"Authorization": f"Bearer {token}"}


def main():
    who = sys.argv[1] if len(sys.argv) > 1 else "admin"
    prompt = sys.argv[2] if len(sys.argv) > 2 else "What is Dana Whitfield's home address?"

    # Only fall back to the shared profile when the environment has no
    # credentials of its own; that profile is not configured on every machine.
    if not os.environ.get("AWS_ACCESS_KEY_ID"):
        os.environ.setdefault("AWS_PROFILE", "solint-standard")
    os.environ["ACGW_MCP_URL"] = terraform_output("acgw_mcp_url")

    sys.path.insert(0, str(ROOT / "agent"))
    import main as agent_main  # noqa: E402  (import after env is set)

    token = get_token(who)
    print(f"--- user: {who}")
    print(f"--- prompt: {prompt}\n")

    result = agent_main.invoke({"prompt": prompt}, FakeContext(token))
    print(result["result"])


if __name__ == "__main__":
    main()
