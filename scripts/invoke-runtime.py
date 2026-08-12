#!/usr/bin/env python3
"""Invoke the deployed agent, either directly or through ACGW-API.

Tokens are bearer tokens, so the AWS SDK cannot be used - it signs with SigV4.
These are plain HTTPS calls with an Authorization header.

  ./scripts/invoke-runtime.py --user admin --diagnostic
  ./scripts/invoke-runtime.py --user admin "What is Dana Whitfield's home address?"
  ./scripts/invoke-runtime.py --user admin --via-gateway --diagnostic
"""

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def terraform_output(name):
    result = subprocess.run(
        ["terraform", "output", "-raw", name],
        cwd=ROOT / "terraform",
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def get_token(who):
    return subprocess.run(
        [str(ROOT / "scripts" / "get-token.sh"), who],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


def build_url(via_gateway):
    region = "us-east-1"
    if via_gateway:
        base = terraform_output("acgw_api_url")
        target = terraform_output("acgw_api_target_name")
        if not base:
            raise SystemExit("ACGW-API is not deployed yet (phase 5).")
        return f"{base.rstrip('/')}/{target}/invocations"

    arn = terraform_output("agent_runtime_arn")
    escaped = urllib.parse.quote(arn, safe="")
    return f"https://bedrock-agentcore.{region}.amazonaws.com/runtimes/{escaped}/invocations?qualifier=DEFAULT"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", default="admin", choices=["admin", "support"])
    parser.add_argument("--diagnostic", action="store_true", help="Check the identity chain without calling a model.")
    parser.add_argument("--via-gateway", action="store_true", help="Invoke through ACGW-API instead of the runtime directly.")
    parser.add_argument("--session", default=None)
    parser.add_argument("prompt", nargs="?", default="What is Dana Whitfield's home address?")
    args = parser.parse_args()

    token = get_token(args.user)
    url = build_url(args.via_gateway)
    body = {"diagnostic": True} if args.diagnostic else {"prompt": args.prompt}

    # The runtime requires a session id of at least 33 characters.
    session_id = args.session or f"{args.user}-{uuid.uuid4().hex}"

    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": session_id,
        },
        method="POST",
    )

    print(f"--- POST {url.split('?')[0]}", file=sys.stderr)
    print(f"--- user: {args.user}  session: {session_id}", file=sys.stderr)

    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            payload = response.read().decode()
            print(f"--- HTTP {response.status}", file=sys.stderr)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode()
        print(f"--- HTTP {exc.code}", file=sys.stderr)
        print(detail)
        sys.exit(1)

    try:
        print(json.dumps(json.loads(payload), indent=2))
    except json.JSONDecodeError:
        print(payload)


if __name__ == "__main__":
    main()
