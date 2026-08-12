# ---------------------------------------------------------------------------
# ACGW-MCP: the tools gateway
#
# Reads the OpenAPI spec from S3 and turns each operation into a tool the agent
# can call. Two separate trust relationships meet here:
#
#   inbound  - the caller presents a Cognito JWT, validated against the user
#              pool's discovery document.
#   outbound - the gateway signs its calls to the mock API with its own
#              execution role, so no API key exists anywhere in the stack.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "gateway_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    # Confused-deputy protection: only this account's AgentCore resources may
    # assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "gateway_mcp" {
  name               = "${var.name_prefix}-acgw-mcp"
  assume_role_policy = data.aws_iam_policy_document.gateway_assume_role.json
}

data "aws_iam_policy_document" "gateway_mcp" {
  # Read the OpenAPI spec that defines the tool surface.
  statement {
    sid       = "ReadOpenApiSpec"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/specs/*"]
  }

  # Call the mock API. This replaces what would otherwise be a stored API key.
  statement {
    sid       = "InvokeMockApi"
    effect    = "Allow"
    actions   = ["execute-api:Invoke"]
    resources = ["${aws_api_gateway_rest_api.mock_api.execution_arn}/*"]
  }

  # Read the authorization rules the gateway enforces on every tool call.
  statement {
    sid    = "ReadPolicyEngine"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:GetPolicyEngine",
      "bedrock-agentcore:GetPolicy",
      "bedrock-agentcore:ListPolicies",
      # Called for every tool invocation to get the allow or deny decision.
      # Both forms are used: the gateway asks about a single action when a tool
      # is called, and about a set of actions when it lists available tools.
      "bedrock-agentcore:AuthorizeAction",
      "bedrock-agentcore:PartiallyAuthorizeActions",
    ]
    # Scoping these to the policy engine ARN is rejected even though the ARN in
    # the denial matches exactly, so they are granted unscoped. The role can
    # only be assumed by this account's AgentCore service, which bounds it.
    # Worth revisiting - see docs/OPEN-QUESTIONS.md.
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gateway_mcp" {
  name   = "${var.name_prefix}-acgw-mcp"
  role   = aws_iam_role.gateway_mcp.id
  policy = data.aws_iam_policy_document.gateway_mcp.json
}

resource "aws_bedrockagentcore_gateway" "mcp" {
  name        = "${var.name_prefix}-acgw-mcp"
  description = "Exposes the customer directory API to the agent as MCP tools."
  role_arn    = aws_iam_role.gateway_mcp.arn

  protocol_type   = "MCP"
  authorizer_type = "CUSTOM_JWT"

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url = local.cognito_discovery_url

      # Cognito access tokens carry client_id rather than aud, so the client
      # is what we match on.
      allowed_clients = [aws_cognito_user_pool_client.web.id]
    }
  }

  protocol_configuration {
    mcp {
      instructions = "Tools for looking up customers and their work and home addresses."
    }
  }

  # Authorization is evaluated here, at the gateway, before any tool call is
  # forwarded to the API. See policy.tf for the rules themselves.
  policy_engine_configuration {
    arn  = aws_bedrockagentcore_policy_engine.main.policy_engine_arn
    mode = var.policy_enforcement_mode
  }

  depends_on = [aws_iam_role_policy.gateway_mcp]
}

resource "aws_bedrockagentcore_gateway_target" "customer_directory" {
  gateway_identifier = aws_bedrockagentcore_gateway.mcp.gateway_id
  name               = var.mcp_target_name
  description        = "Customer directory REST API, exposed as tools via its OpenAPI specification."

  target_configuration {
    mcp {
      open_api_schema {
        s3 {
          uri = "s3://${aws_s3_bucket.artifacts.id}/${aws_s3_object.openapi_spec.key}"
        }
      }
    }
  }

  # Sign outbound calls with the gateway's own role rather than a stored
  # credential.
  credential_provider_configuration {
    gateway_iam_role {
      service = "execute-api"
      region  = var.aws_region
    }
  }
}
