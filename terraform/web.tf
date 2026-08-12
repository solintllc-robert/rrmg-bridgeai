# ---------------------------------------------------------------------------
# The edge: S3, CloudFront, and a web firewall
#
# One distribution serves two things:
#
#   /*      the browser application and the API documentation, from S3
#   /api/*  the agent, from ACGW-API
#
# Serving both from one domain is what makes the browser same-origin with the
# agent. That matters because AgentCore sends no CORS headers, so a browser
# calling it from a different origin would be blocked outright.
#
# The front-door target is named "api", so the gateway's own path is
# /api/invocations and CloudFront can forward the request untouched. Naming it
# anything else would need a URL-rewriting function here.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "web" {
  bucket = local.web_bucket_name
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket = aws_s3_bucket.web.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "web" {
  bucket = aws_s3_bucket.web.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = aws_s3_bucket.web.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# The bucket stays private. CloudFront reaches it through this signed identity
# rather than the bucket being readable from the internet.
resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${var.name_prefix}-web-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "web_bucket" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web_bucket.json
}

# ---------------------------------------------------------------------------
# Web firewall
#
# Scope must be CLOUDFRONT and the ACL must live in us-east-1, which is where
# this stack already is.
# ---------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "web" {
  name        = "${var.name_prefix}-web-acl"
  description = "Protects the customer directory assistant."
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # AWS's baseline protections: common exploit patterns, bad inputs.
  rule {
    name     = "common-rule-set"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  # Blunt protection against a runaway client or scripted abuse. Each agent
  # call costs real money, so this is a cost control as much as a security one.
  rule {
    name     = "rate-limit"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-web-acl"
    sampled_requests_enabled   = true
  }
}

# ---------------------------------------------------------------------------
# Distribution
# ---------------------------------------------------------------------------

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# Forwards every viewer header except Host. The agent needs the Authorization
# header and the session id header; Host must be the gateway's own.
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

locals {
  acgw_api_host = replace(replace(aws_bedrockagentcore_gateway.api.gateway_url, "https://", ""), "/", "")
}

resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  comment             = "${var.name_prefix} customer directory assistant"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  web_acl_id          = aws_wafv2_web_acl.web.arn

  origin {
    origin_id                = "web-bucket"
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  origin {
    origin_id   = "acgw-api"
    domain_name = local.acgw_api_host

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # The browser application and documentation.
  default_cache_behavior {
    target_origin_id       = "web-bucket"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
    compress               = true
  }

  # The agent. Never cached: every request is a distinct question, and the
  # Authorization header must reach the gateway untouched.
  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "acgw-api"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = false
  }

  # The application handles its own routes, so a request for a path S3 does not
  # have is not an error - it is a deep link. Serve the app and let it route.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Using CloudFront's own certificate on the *.cloudfront.net name. The
  # minimum TLS version is fixed by AWS in this mode and cannot be set here;
  # specifying it produces a diff on every plan that never settles. It becomes
  # configurable once a custom domain and ACM certificate are introduced.
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
