# Private bucket holding build artifacts the AWS services read directly:
# the OpenAPI spec consumed by ACGW-MCP, and later the agent code zip.
resource "aws_s3_bucket" "artifacts" {
  bucket = local.artifacts_bucket_name
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# The spec's `servers` URL is only known once the API Gateway stage exists, so
# it is templated in at apply time rather than hardcoded.
resource "aws_s3_object" "openapi_spec" {
  bucket       = aws_s3_bucket.artifacts.id
  key          = "specs/customer-directory-openapi.yaml"
  content_type = "application/yaml"

  content = templatefile("${path.module}/../mock-api/spec/openapi.yaml.tftpl", {
    api_base_url = aws_api_gateway_stage.mock_api.invoke_url
  })
}
