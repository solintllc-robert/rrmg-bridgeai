#!/usr/bin/env python3
"""Render the OpenAPI specification into a static documentation page.

Deliberately produces plain HTML with no external scripts or styles. The usual
documentation viewers pull their code from a public CDN at page load, which
would put part of this system outside AWS. Generating the page at build time
keeps everything self-contained.

  uv run --with pyyaml scripts/build-docs.py --spec <file> --base-url <url> --out <file>
"""

import argparse
import html
import pathlib

import yaml

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
:root {{
  --bg:#f6f7f9; --panel:#fff; --ink:#1c2024; --muted:#6b7280;
  --line:#e3e6ea; --accent:#1f5eff; --get:#0a7c42; --code:#f0f2f5;
}}
@media (prefers-color-scheme: dark) {{
  :root {{
    --bg:#14161a; --panel:#1c1f24; --ink:#e8eaed; --muted:#9aa3ad;
    --line:#2c3037; --accent:#6b93ff; --get:#4ac585; --code:#22262c;
  }}
}}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--ink);
  font:15px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; }}
.wrap {{ max-width:860px; margin:0 auto; padding:32px 20px 64px; }}
h1 {{ font-size:26px; margin:0 0 8px; }}
h2 {{ font-size:19px; margin:36px 0 12px; padding-top:20px; border-top:1px solid var(--line); }}
h3 {{ font-size:15px; margin:20px 0 8px; color:var(--muted);
  text-transform:uppercase; letter-spacing:.05em; }}
code, .mono {{ font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.9em; }}
.server {{ background:var(--panel); border:1px solid var(--line); border-radius:8px;
  padding:12px 14px; margin:16px 0 8px; }}
.op {{ background:var(--panel); border:1px solid var(--line); border-radius:10px;
  padding:18px 20px; margin-bottom:16px; }}
.path {{ display:flex; align-items:center; gap:10px; flex-wrap:wrap; }}
.verb {{ background:var(--get); color:#fff; border-radius:5px; padding:2px 9px;
  font-size:12px; font-weight:600; letter-spacing:.04em; }}
.route {{ font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:14px; font-weight:600; }}
.tool {{ margin-left:auto; color:var(--muted); font-size:12px; }}
.desc {{ margin:10px 0 0; }}
table {{ border-collapse:collapse; width:100%; margin-top:6px; }}
th, td {{ text-align:left; padding:7px 10px; border-bottom:1px solid var(--line);
  vertical-align:top; font-size:14px; }}
th {{ color:var(--muted); font-weight:600; font-size:12px;
  text-transform:uppercase; letter-spacing:.04em; }}
td.name {{ font-family:ui-monospace,SFMono-Regular,Menlo,monospace; white-space:nowrap; }}
.req {{ color:var(--accent); font-size:11px; margin-left:4px; }}
.note {{ background:var(--code); border-radius:8px; padding:14px 16px; margin:16px 0; }}
.muted {{ color:var(--muted); }}
a {{ color:var(--accent); }}
</style>
</head>
<body>
<div class="wrap">
<h1>{title}</h1>
<p class="muted">{description}</p>

<div class="server">
  <strong>Base URL</strong><br>
  <span class="mono">{base_url}</span>
</div>

<div class="note">
  <strong>Access.</strong> Requests must be signed with AWS credentials
  (SigV4, <span class="mono">execute-api</span>). There is no API key. In this
  system the caller is the tools gateway, which signs with its own role, so the
  agent never handles a credential for this API.
  <br><br>
  <strong>Tool names.</strong> Each operation below is exposed to the agent as
  a tool named <span class="mono">{target}___&lt;operationId&gt;</span>.
</div>

{operations}

<h2>Data shapes</h2>
{schemas}

<p class="muted" style="margin-top:40px">
Generated from the OpenAPI specification. Version {version}.
</p>
</div>
</body>
</html>
"""


def esc(value):
    return html.escape(str(value or "").strip())


def render_parameters(parameters):
    if not parameters:
        return '<p class="muted">No parameters.</p>'

    rows = []
    for parameter in parameters:
        schema = parameter.get("schema", {})
        kind = schema.get("type", "string")
        if schema.get("enum"):
            kind += " — one of " + ", ".join(f"<code>{esc(v)}</code>" for v in schema["enum"])
        required = '<span class="req">required</span>' if parameter.get("required") else ""
        rows.append(
            f'<tr><td class="name">{esc(parameter["name"])}{required}</td>'
            f"<td>{esc(parameter.get('in'))}</td>"
            f"<td>{kind}</td>"
            f"<td>{esc(parameter.get('description'))}</td></tr>"
        )

    return (
        "<table><tr><th>Name</th><th>In</th><th>Type</th><th>Description</th></tr>"
        + "".join(rows)
        + "</table>"
    )


def render_operations(spec, target):
    blocks = []
    for route, methods in spec.get("paths", {}).items():
        for method, operation in methods.items():
            blocks.append(
                f"""
<div class="op">
  <div class="path">
    <span class="verb">{method.upper()}</span>
    <span class="route">{esc(route)}</span>
    <span class="tool">tool: {esc(target)}___{esc(operation.get("operationId"))}</span>
  </div>
  <p class="desc"><strong>{esc(operation.get("summary"))}</strong><br>
     {esc(operation.get("description"))}</p>
  <h3>Parameters</h3>
  {render_parameters(operation.get("parameters"))}
</div>"""
            )
    return "\n".join(blocks)


def render_schemas(spec):
    blocks = []
    schemas = spec.get("components", {}).get("schemas", {})
    for name, schema in schemas.items():
        rows = []
        for field, definition in (schema.get("properties") or {}).items():
            kind = definition.get("type", "object")
            if definition.get("$ref"):
                kind = definition["$ref"].split("/")[-1]
            rows.append(
                f'<tr><td class="name">{esc(field)}</td><td>{esc(kind)}</td>'
                f"<td>{esc(definition.get('description'))}</td></tr>"
            )
        table = (
            "<table><tr><th>Field</th><th>Type</th><th>Description</th></tr>"
            + "".join(rows)
            + "</table>"
        )
        blocks.append(f'<div class="op"><div class="path"><span class="route">{esc(name)}</span></div>{table}</div>')
    return "\n".join(blocks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--target", default="customer-directory")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    raw = pathlib.Path(args.spec).read_text()
    # The checked-in spec is a template; fill the one placeholder it carries.
    raw = raw.replace("${api_base_url}", args.base_url)
    spec = yaml.safe_load(raw)

    info = spec.get("info", {})
    page = PAGE.format(
        title=esc(info.get("title", "API")),
        description=esc(info.get("description")),
        version=esc(info.get("version")),
        base_url=esc(args.base_url),
        target=esc(args.target),
        operations=render_operations(spec, args.target),
        schemas=render_schemas(spec),
    )

    out_file = pathlib.Path(args.out)
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text(page)
    print(f"Wrote {out_file} ({len(page)} bytes)")


if __name__ == "__main__":
    main()
