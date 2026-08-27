#!/usr/bin/env bash
# Build the agent deployment package for AgentCore Runtime.
#
# AgentCore Runtime runs on arm64 Amazon Linux, so dependencies are downloaded
# as arm64 wheels rather than built locally. The resulting zip has the
# libraries and main.py together at the root, which is where the runtime looks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_DIR="$ROOT/agent"
BUILD_DIR="$ROOT/terraform/build"
STAGE_DIR="$BUILD_DIR/agent-package"
ZIP_PATH="$BUILD_DIR/agent.zip"

PYTHON_VERSION="3.13"
PLATFORM="aarch64-manylinux2014"

echo "==> Staging dependencies ($PLATFORM, python $PYTHON_VERSION)"
rm -rf "$STAGE_DIR" "$ZIP_PATH"
mkdir -p "$STAGE_DIR"

# uv hardlinks out of its cache by default, which fails when the working copy
# is on OneDrive or another filesystem that does not support hardlinks.
uv pip install \
  --python-platform "$PLATFORM" \
  --python-version "$PYTHON_VERSION" \
  --target "$STAGE_DIR" \
  --only-binary=:all: \
  --link-mode=copy \
  --quiet \
  -r "$AGENT_DIR/pyproject.toml"

echo "==> Adding agent source"
cp "$AGENT_DIR/main.py" "$STAGE_DIR/main.py"

# Bytecode compiled on this machine may not match the runtime's architecture.
find "$STAGE_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$STAGE_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true

# Python rather than zip(1), which Git Bash on Windows does not ship. Candidates
# are tested by running them because Windows puts stubs on PATH that exist but
# fail, so command -v is not enough to tell whether one works.
PYTHON=""
for candidate in python3 python py; do
  if "$candidate" -c "import zipfile" >/dev/null 2>&1; then
    PYTHON="$candidate"
    break
  fi
done
if [[ -z "$PYTHON" ]]; then
  echo "ERROR: no working python found; tried python3, python, py" >&2
  exit 1
fi

echo "==> Zipping"
"$PYTHON" - "$STAGE_DIR" "$ZIP_PATH" <<'PYTHON_SCRIPT'
import os
import sys
import zipfile

stage, out = sys.argv[1], sys.argv[2]

# Modes are written into the archive rather than read off the staged files: the
# runtime needs 755 on directories and 644 on files, and a build host may not
# report either (Windows has no execute bit). Entries are sorted and left at
# zipfile's default 1980 timestamp so the same input produces the same archive.
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
    for root, dirs, files in os.walk(stage):
        dirs.sort()
        for name in dirs + sorted(files):
            path = os.path.join(root, name)
            arcname = os.path.relpath(path, stage).replace(os.sep, "/")
            is_dir = os.path.isdir(path)
            entry = zipfile.ZipInfo(arcname + "/" if is_dir else arcname)
            entry.external_attr = (0o40755 if is_dir else 0o100644) << 16
            if is_dir:
                archive.writestr(entry, b"")
            else:
                entry.compress_type = zipfile.ZIP_DEFLATED
                with open(path, "rb") as handle:
                    archive.writestr(entry, handle.read())
PYTHON_SCRIPT

SIZE_MB=$(( $(stat -c%s "$ZIP_PATH") / 1024 / 1024 ))
echo "==> Built $ZIP_PATH (${SIZE_MB} MB zipped; limit is 250 MB)"

if [[ "$SIZE_MB" -gt 250 ]]; then
  echo "ERROR: package exceeds the 250 MB direct-deploy limit" >&2
  exit 1
fi
