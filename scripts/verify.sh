#!/usr/bin/env bash
# End-to-end check of the deployed stack.
#
# Runs every check that does not need a language model, so it stays useful
# while Bedrock model access is pending. Prints a pass or fail line per check
# and exits non-zero if any fail.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-solint-standard}"
cd "$ROOT/terraform"

PASS=0
FAIL=0

check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf "  \033[32mPASS\033[0m  %-52s %s\n" "$1" "$3"
    PASS=$((PASS + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-52s got %s, wanted %s\n" "$1" "$3" "$2"
    FAIL=$((FAIL + 1))
  fi
}

contains() { # contains <name> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then
    printf "  \033[32mPASS\033[0m  %s\n" "$1"
    PASS=$((PASS + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-52s missing %s\n" "$1" "$2"
    FAIL=$((FAIL + 1))
  fi
}

API="$(terraform output -raw mock_api_base_url)"
SITE="$(terraform output -raw site_url)"
MCP="$(terraform output -raw acgw_mcp_url)"
BUCKET="$(terraform output -raw web_bucket)"

echo
echo "1. Mock API — reachable only with an AWS signature"
eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env)"
sig() { curl -s --aws-sigv4 "aws:amz:us-east-1:execute-api" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
  -H "x-amz-security-token: $AWS_SESSION_TOKEN" "$API$1"; }

check "unsigned request is rejected" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$API/customers")"
contains "signed search finds the customer" "Dana Whitfield" "$(sig '/customers?name=dana')"
contains "home address endpoint returns a street" "Harrowgate" "$(sig '/customers/C-1001/home-address')"
if [[ "$(sig '/customers/C-1001')" == *"home_address"* ]]; then
  printf "  \033[31mFAIL\033[0m  core record leaks an address\n"; FAIL=$((FAIL + 1))
else
  printf "  \033[32mPASS\033[0m  core record contains no address\n"; PASS=$((PASS + 1))
fi

echo
echo "2. Sign-in — each user carries the right group"
ADMIN="$("$ROOT/scripts/get-token.sh" admin)"
SUPPORT="$("$ROOT/scripts/get-token.sh" support)"
contains "admin token says customer-admin" "customer-admin" \
  "$(echo "$ADMIN" | "$ROOT/scripts/decode-jwt.sh")"
contains "support token says customer-support" "customer-support" \
  "$(echo "$SUPPORT" | "$ROOT/scripts/decode-jwt.sh")"

echo
echo "3. Tools gateway — tools built from the API description"
TOOLS="$("$ROOT/scripts/mcp_client.py" --token "$ADMIN" --url "$MCP" list 2>/dev/null)"
check "four tools are published" "4 tools:" "$(echo "$TOOLS" | grep -o '^4 tools:')"

echo
echo "4. Permission rules — enforced at the gateway, not by the agent"
call() { "$ROOT/scripts/mcp_client.py" --token "$1" --url "$MCP" call \
  "customer-directory___$2" "$3" 2>/dev/null; }

contains "admin may read a home address" "Harrowgate" \
  "$(call "$ADMIN" getCustomerHomeAddress '{"customerId":"C-1001"}')"
contains "support may NOT read a home address" "not allowed due to policy" \
  "$(call "$SUPPORT" getCustomerHomeAddress '{"customerId":"C-1001"}')"
contains "support may read a work address" "Seaport" \
  "$(call "$SUPPORT" getCustomerWorkAddress '{"customerId":"C-1001"}')"

echo
echo "5. Agent — the caller's identity survives every hop"
DIAG="$("$ROOT/scripts/invoke-runtime.py" --user admin --via-gateway --diagnostic 2>/dev/null)"
contains "agent sees the caller's group" "customer-admin" "$DIAG"
contains "agent reaches the tools gateway as that caller" "getCustomerHomeAddress" "$DIAG"

echo
echo "6. Runtime — refuses callers without a valid token"
ARN="$(terraform output -raw agent_runtime_arn)"
ESC="$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$ARN")"
URL="https://bedrock-agentcore.us-east-1.amazonaws.com/runtimes/$ESC/invocations?qualifier=DEFAULT"
check "no token is rejected" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL" \
  -H 'Content-Type: application/json' \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: verify-$(uuidgen)" -d '{"diagnostic":true}')"
check "an invalid token is rejected" "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL" \
  -H 'Authorization: Bearer not.a.real.token' -H 'Content-Type: application/json' \
  -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: verify2-$(uuidgen)" -d '{"diagnostic":true}')"

echo
echo "7. Public site"
check "application loads" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$SITE/")"
check "documentation loads" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$SITE/docs.html")"
check "deep link falls back to the application" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$SITE/callback")"
check "storage is not readable directly" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' "https://${BUCKET}.s3.amazonaws.com/index.html")"
contains "agent reachable through the site address" "customer-admin" \
  "$(curl -s -X POST "$SITE/api/invocations" -H "Authorization: Bearer $ADMIN" \
     -H 'Content-Type: application/json' \
     -H "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: verify3-$(uuidgen)" \
     -d '{"diagnostic":true}')"

echo
echo "8. Housekeeping"
check "every resource is tagged" "15" "$(aws resourcegroupstaggingapi get-resources --region us-east-1 \
  --tag-filters Key=project,Values=bridge.ai Key=poc,Values=rrmg \
  --query 'length(ResourceTagMappingList)' --output text)"
terraform plan -no-color -detailed-exitcode >/dev/null 2>&1
check "deployed state matches the code" "0" "$?"

echo
echo "-------------------------------------------------------------------"
printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
echo "  Not covered: the agent writing an answer (no model access yet),"
echo "  and sign-in through a real browser. See docs/TEST-RESULTS.md."
echo
[[ "$FAIL" -eq 0 ]]
