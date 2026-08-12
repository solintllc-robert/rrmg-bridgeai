data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Bucket names are globally unique, so the account id keeps this stack
  # re-appliable in a different account without editing any values.
  artifacts_bucket_name = "${var.name_prefix}-artifacts-${local.account_id}"
}
