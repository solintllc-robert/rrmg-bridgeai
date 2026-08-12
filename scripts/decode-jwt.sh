#!/usr/bin/env bash
# Decode a JWT payload without verifying the signature, for inspection.
#   ./scripts/get-token.sh admin | ./scripts/decode-jwt.sh
set -euo pipefail

TOKEN="${1:-$(cat)}"
python3 - "$TOKEN" <<'PY'
import base64, json, sys
payload = sys.argv[1].strip().split(".")[1]
payload += "=" * (-len(payload) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(payload)), indent=2, sort_keys=True))
PY
