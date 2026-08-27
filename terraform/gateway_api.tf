# ---------------------------------------------------------------------------
# ACGW-API: the front door
#
# A gateway with no protocol type, routing straight to the agent runtime. It
# exists to give the outside world a clean, stable URL:
#
#   https://<gateway-id>.gateway.bedrock-agentcore.<region>.amazonaws.com/<target>/invocations
#
# Invoking the runtime directly instead would mean putting a URL-encoded ARN in
# the path, which CloudFront cannot be relied upon to forward intact.
#
# The caller's token is passed through unchanged, so the runtime still sees the
# end user's identity rather than the gateway's.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "gateway_api" {
  name               = "${var.name_prefix}-acgw-api"
  path               = var.iam_role_path
  assume_role_policy = data.aws_iam_policy_document.gateway_assume_role.json
}

data "aws_iam_policy_document" "gateway_api" {
  statement {
    sid    = "InvokeAgentRuntime"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:InvokeAgentRuntime",
    ]
    # Matched by name pattern rather than by referencing the runtime resource,
    # to avoid a dependency cycle. See the note in runtime.tf.
    resources = [
      local.agent_runtime_pattern,
      "${local.agent_runtime_pattern}/*",
    ]
  }
}

resource "aws_iam_role_policy" "gateway_api" {
  name   = "${var.name_prefix}-acgw-api"
  role   = aws_iam_role.gateway_api.id
  policy = data.aws_iam_policy_document.gateway_api.json
}

resource "aws_bedrockagentcore_gateway" "api" {
  name        = "${var.name_prefix}-acgw-api"
  description = "Front door for the customer directory agent."
  role_arn    = aws_iam_role.gateway_api.arn

  # No protocol_type: this gateway routes to HTTP targets rather than
  # aggregating MCP tools. A runtime target cannot be attached to an MCP
  # gateway, which is why this is separate from ACGW-MCP.
  authorizer_type = "CUSTOM_JWT"

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = local.cognito_discovery_url
      allowed_clients = [aws_cognito_user_pool_client.web.id]
    }
  }

  depends_on = [aws_iam_role_policy.gateway_api]
}

resource "aws_bedrockagentcore_gateway_target" "agent" {
  gateway_identifier = aws_bedrockagentcore_gateway.api.gateway_id
  name               = var.acgw_api_target_name
  description        = "Routes requests to the customer directory agent runtime."

  target_configuration {
    http {
      agentcore_runtime {
        arn       = aws_bedrockagentcore_agent_runtime.agent.agent_runtime_arn
        qualifier = "DEFAULT"
      }
    }
  }

  # Forward the caller's token to the runtime untouched, so the end user's
  # identity survives the hop rather than being replaced by the gateway's.
  credential_provider_configuration {
    jwt_passthrough {}
  }
}
