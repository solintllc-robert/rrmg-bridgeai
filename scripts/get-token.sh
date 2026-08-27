#!/usr/bin/env bash
# Fetch a Cognito access token for one of the two test users.
#
#   ./scripts/get-token.sh admin     -> token for the customer-admin user
#   ./scripts/get-token.sh support   -> token for the customer-support user
#
# Prints the raw access token on stdout so it can be captured directly:
#   TOKEN=$(./scripts/get-token.sh admin)
set -euo pipefail

WHO="${1:-admin}"
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
# Only fall back to the shared profile when the environment has no credentials
# of its own; that profile is not configured on every machine.
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]] || export AWS_PROFILE="${AWS_PROFILE:-solint-standard}"

case "$WHO" in
  admin)   USER_VAR="admin_user_email";   PASS_VAR="admin_user_password"   ;;
  support) USER_VAR="support_user_email"; PASS_VAR="support_user_password" ;;
  *) echo "usage: $0 [admin|support]" >&2; exit 2 ;;
esac

cd "$TF_DIR"
CLIENT_ID="$(terraform output -raw cognito_client_id)"
PASSWORD="$(terraform output -raw "$PASS_VAR")"
USERNAME="$(terraform output -raw "$USER_VAR" 2>/dev/null || true)"

# The email addresses are inputs rather than outputs, so fall back to reading
# the variable default straight out of the plan values.
if [[ -z "$USERNAME" ]]; then
  USERNAME="$(terraform console -no-color <<<"var.${USER_VAR}" | tr -d '"')"
fi

aws cognito-idp initiate-auth \
  --client-id "$CLIENT_ID" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters "USERNAME=${USERNAME},PASSWORD=${PASSWORD}" \
  --query 'AuthenticationResult.AccessToken' \
  --output text
