# ---------------------------------------------------------------------------
# Cognito: the identity store
#
# Stands in for the enterprise identity provider. It issues the JWT that every
# component downstream trusts: ACGW-API, the agent runtime, and ACGW-MCP all
# validate tokens minted here.
#
# Group membership is the authorization signal. Cognito places a
# `cognito:groups` claim in the access token, and the Cedar policy on ACGW-MCP
# reads it to decide who may see a customer's home address.
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "main" {
  name = "${var.name_prefix}-users"

  # Sign in with an email address rather than a separate username.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.name_prefix}-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

# A public client: no secret, because the code runs in a browser where a
# secret could not be kept. PKCE protects the authorization code instead.
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.name_prefix}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false

  # USER_PASSWORD_AUTH is enabled so tokens can be fetched from the command
  # line for testing. See docs/OPEN-QUESTIONS.md (Q1).
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = local.cognito_callback_urls
  logout_urls   = local.cognito_logout_urls

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 1

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
}

# ---------------------------------------------------------------------------
# Groups: the authorization signal carried in the token
# ---------------------------------------------------------------------------

resource "aws_cognito_user_group" "customer_admin" {
  name         = "customer-admin"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "May read customer home addresses in addition to all other customer data."
  precedence   = 1
}

resource "aws_cognito_user_group" "customer_support" {
  name         = "customer-support"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "May read customer records and work addresses, but not home addresses."
  precedence   = 10
}

# ---------------------------------------------------------------------------
# Test users
#
# Passwords are generated at apply time and surfaced as sensitive outputs, so
# no credential is ever written into the repository.
# ---------------------------------------------------------------------------

resource "random_password" "admin_user" {
  length           = 20
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%*-_"
}

resource "random_password" "support_user" {
  length           = 20
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%*-_"
}

resource "aws_cognito_user" "admin" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = var.admin_user_email
  password     = random_password.admin_user.result

  attributes = {
    email          = var.admin_user_email
    email_verified = true
  }
}

resource "aws_cognito_user" "support" {
  user_pool_id = aws_cognito_user_pool.main.id
  username     = var.support_user_email
  password     = random_password.support_user.result

  attributes = {
    email          = var.support_user_email
    email_verified = true
  }
}

resource "aws_cognito_user_in_group" "admin" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.customer_admin.name
  username     = aws_cognito_user.admin.username
}

resource "aws_cognito_user_in_group" "support" {
  user_pool_id = aws_cognito_user_pool.main.id
  group_name   = aws_cognito_user_group.customer_support.name
  username     = aws_cognito_user.support.username
}
