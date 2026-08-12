#!/usr/bin/env python3
"""Minimal MCP client for exercising ACGW-MCP directly.

Speaks just enough of the MCP streamable-HTTP transport to initialize a
session, list the tools the gateway generated from the OpenAPI spec, and call
one. Used to test the gateway on its own, before any agent exists.

  ./scripts/mcp_client.py --token "$TOKEN" list
  ./scripts/mcp_client.py --token "$TOKEN" call searchCustomers '{"name":"dana"}'
"""

import argparse
import json
import sys
import urllib.error
import urllib.request


class McpClient:
    def __init__(self, url, token):
        self.url = url
        self.token = token
        self.session_id = None
        self._next_id = 0

    def _post(self, method, params=None, notification=False):
        payload = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        if not notification:
            self._next_id += 1
            payload["id"] = self._next_id

        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id

        request = urllib.request.Request(
            self.url, data=json.dumps(payload).encode(), headers=headers, method="POST"
        )

        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                session = response.headers.get("Mcp-Session-Id")
                if session:
                    self.session_id = session
                body = response.read().decode()
                content_type = response.headers.get("Content-Type", "")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode()
            raise SystemExit(f"HTTP {exc.code} calling {method}\n{detail}") from None

        if notification or not body.strip():
            return None
        return _parse(body, content_type)

    def initialize(self):
        result = self._post(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "bridgeai-test-client", "version": "1.0.0"},
            },
        )
        self._post("notifications/initialized", {}, notification=True)
        return result

    def list_tools(self):
        return self._post("tools/list", {})

    def call_tool(self, name, arguments):
        return self._post("tools/call", {"name": name, "arguments": arguments})


def _parse(body, content_type):
    """Return the JSON-RPC payload from either a plain or SSE response."""
    if "text/event-stream" in content_type:
        for line in body.splitlines():
            if line.startswith("data:"):
                return json.loads(line[5:].strip())
        raise SystemExit(f"No data frame in event stream:\n{body}")
    return json.loads(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("command", choices=["list", "call"])
    parser.add_argument("tool", nargs="?")
    parser.add_argument("arguments", nargs="?", default="{}")
    args = parser.parse_args()

    client = McpClient(args.url, args.token)
    info = client.initialize()
    server = (info or {}).get("result", {}).get("serverInfo", {})
    print(f"connected: {server.get('name', 'unknown')} {server.get('version', '')}", file=sys.stderr)

    if args.command == "list":
        response = client.list_tools()
        tools = response.get("result", {}).get("tools", [])
        print(f"{len(tools)} tools:")
        for tool in tools:
            params = list((tool.get("inputSchema") or {}).get("properties", {}))
            print(f"  - {tool['name']}({', '.join(params)})")
            description = (tool.get("description") or "").strip().replace("\n", " ")
            if description:
                print(f"      {description[:110]}")
        return

    if not args.tool:
        raise SystemExit("call requires a tool name")
    response = client.call_tool(args.tool, json.loads(args.arguments))
    print(json.dumps(response, indent=2))


if __name__ == "__main__":
    main()
