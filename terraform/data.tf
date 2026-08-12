data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Bucket names are globally unique, so the account id keeps this stack
  # re-appliable in a different account without editing any values.
  artifacts_bucket_name = "${var.name_prefix}-artifacts-${local.account_id}"
  web_bucket_name       = "${var.name_prefix}-web-${local.account_id}"

  # Where Cognito is allowed to send the browser after sign-in and sign-out.
  # The local dev server is listed alongside the deployed site so the same
  # user pool serves both. The deployed entry is added in phase 8, once the
  # CloudFront distribution exists.
  # Both the local dev server and the deployed site are registered, so the same
  # user pool serves whichever one is in use.
  #
  # The deployed origin arrives as a variable rather than by reading the
  # CloudFront resource directly, because doing so would form a loop: the
  # Cognito client would depend on CloudFront, CloudFront on ACGW-API, and
  # ACGW-API back on the Cognito client for its allowed client id. Passing the
  # value in cuts the loop. scripts/deploy-web.sh supplies it automatically.
  cognito_callback_urls = concat(
    ["${var.local_web_origin}/callback"],
    var.deployed_web_origin == "" ? [] : ["${var.deployed_web_origin}/callback"],
  )

  cognito_logout_urls = concat(
    [var.local_web_origin],
    var.deployed_web_origin == "" ? [] : [var.deployed_web_origin],
  )

  # The OIDC discovery document every JWT authorizer in the stack points at.
  cognito_discovery_url = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}/.well-known/openid-configuration"

  cognito_issuer = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}
