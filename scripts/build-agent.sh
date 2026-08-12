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

uv pip install \
  --python-platform "$PLATFORM" \
  --python-version "$PYTHON_VERSION" \
  --target "$STAGE_DIR" \
  --only-binary=:all: \
  --quiet \
  -r "$AGENT_DIR/pyproject.toml"

echo "==> Adding agent source"
cp "$AGENT_DIR/main.py" "$STAGE_DIR/main.py"

# Bytecode compiled on this machine may not match the runtime's architecture.
find "$STAGE_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$STAGE_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true

# The runtime needs 644 on files and 755 on directories to read the package.
find "$STAGE_DIR" -type d -exec chmod 755 {} +
find "$STAGE_DIR" -type f -exec chmod 644 {} +

echo "==> Zipping"
(cd "$STAGE_DIR" && zip -qr "$ZIP_PATH" .)

SIZE_MB=$(( $(stat -c%s "$ZIP_PATH") / 1024 / 1024 ))
echo "==> Built $ZIP_PATH (${SIZE_MB} MB zipped; limit is 250 MB)"

if [[ "$SIZE_MB" -gt 250 ]]; then
  echo "ERROR: package exceeds the 250 MB direct-deploy limit" >&2
  exit 1
fi
