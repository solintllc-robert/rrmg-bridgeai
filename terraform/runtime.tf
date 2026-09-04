# ---------------------------------------------------------------------------
# AgentCore Runtime: where the agent runs
#
# Deployed as a zip rather than a container, so no Docker is needed anywhere in
# the build. The runtime validates the caller's Cognito token before the agent
# code executes, and forwards the Authorization header through so the agent can
# reuse the caller's identity when it calls ACGW-MCP.
# ---------------------------------------------------------------------------

locals {
  # Rebuild the package whenever the agent's own source changes. Both files are
  # always present in the repository, so this is safe to evaluate at plan time
  # even before the package has ever been built.
  agent_source_hash = sha256(join("", [
    filesha256("${path.module}/../agent/main.py"),
    filesha256("${path.module}/../agent/pyproject.toml"),
  ]))

  agent_zip_path = "${path.module}/build/agent.zip"
  agent_code_key = "agent/agent.zip"

  # AgentCore appends a generated suffix to the runtime name, so policies that
  # must not depend on the runtime resource itself match on this prefix.
  # Referencing the resource directly here would create a dependency cycle:
  # the runtime points at ACGW-API for its workload restriction, and ACGW-API's
  # role would point back at the runtime.
  agent_runtime_name    = replace("${var.name_prefix}_agent", "-", "_")
  agent_runtime_pattern = "arn:aws:bedrock-agentcore:${var.aws_region}:${local.account_id}:runtime/${replace("${var.name_prefix}_agent", "-", "_")}-*"
}

resource "terraform_data" "build_agent" {
  triggers_replace = local.agent_source_hash

  provisioner "local-exec" {
    # Named explicitly because the default interpreter on Windows is cmd.exe,
    # which cannot run a shell script.
    interpreter = ["bash", "-c"]
    command     = "${path.module}/../scripts/build-agent.sh"
  }
}

resource "aws_s3_object" "agent_code" {
  bucket      = aws_s3_bucket.artifacts.id
  key         = local.agent_code_key
  source      = local.agent_zip_path
  source_hash = local.agent_source_hash

  depends_on = [terraform_data.build_agent]
}

# ---------------------------------------------------------------------------
# Execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "runtime" {
  name               = "${var.name_prefix}-runtime"
  path               = var.iam_role_path
  assume_role_policy = data.aws_iam_policy_document.gateway_assume_role.json
}

data "aws_iam_policy_document" "runtime" {
  statement {
    sid    = "InvokeModel"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    # Inference profiles route across regions, so both the profile and the
    # underlying foundation models must be allowed.
    resources = [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:*:${local.account_id}:inference-profile/*",
    ]
  }

  statement {
    sid    = "ReadAgentCode"
    effect = "Allow"
    # The code is pinned to an object version below, and a version-scoped read
    # needs its own permission - GetObject alone covers only the current one.
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.artifacts.arn}/${local.agent_code_key}"]
  }

  statement {
    sid    = "ConversationMemory"
    effect = "Allow"
    # Exactly the data-plane calls the Strands session manager makes: it
    # appends each turn as an event and lists them back at the start of the
    # next one.
    actions = [
      "bedrock-agentcore:CreateEvent",
      "bedrock-agentcore:GetEvent",
      "bedrock-agentcore:ListEvents",
      "bedrock-agentcore:DeleteEvent",
    ]
    resources = [
      aws_bedrockagentcore_memory.conversations.arn,
      "${aws_bedrockagentcore_memory.conversations.arn}/*",
    ]
  }

  # RetrieveMemoryRecords is deliberately not granted above. It is the call
  # that reads long-term memory, and with no strategies attached there is
  # nothing for it to read - but leaving it out means that if a strategy is
  # ever added without revisiting the authorization question in memory.tf,
  # retrieval fails loudly instead of quietly replaying facts to somebody the
  # gateway would now refuse.

  statement {
    sid    = "Observability"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "cloudwatch:PutMetricData",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "runtime" {
  name   = "${var.name_prefix}-runtime"
  role   = aws_iam_role.runtime.id
  policy = data.aws_iam_policy_document.runtime.json
}

# ---------------------------------------------------------------------------
# The runtime itself
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_agent_runtime" "agent" {
  agent_runtime_name = local.agent_runtime_name
  description        = "Customer directory agent for the bridge.ai proof of concept."
  role_arn           = aws_iam_role.runtime.arn

  agent_runtime_artifact {
    code_configuration {
      runtime     = "PYTHON_3_13"
      entry_point = ["main.py"]

      code {
        s3 {
          bucket = aws_s3_bucket.artifacts.id
          prefix = local.agent_code_key

          # Pin the object version: re-uploading to the same key changes
          # neither bucket nor prefix, so without this Terraform sees no diff
          # and the runtime keeps serving the code it first loaded.
          version_id = aws_s3_object.agent_code.version_id
        }
      }
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  # Inbound: only tokens from our Cognito user pool, issued to our app client.
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = local.cognito_discovery_url
      allowed_clients = [aws_cognito_user_pool_client.web.id]

      # With this set, a valid user token is no longer sufficient on its own:
      # the request must also have arrived through ACGW-API. That closes the
      # gap where somebody holding a token calls the runtime directly and
      # bypasses CloudFront, the firewall, and everything else at the edge.
      dynamic "allowed_workload_configuration" {
        for_each = var.restrict_runtime_to_gateway ? [1] : []

        content {
          # Identify the gateway by workload identity name as well as by ARN.
          # A request is accepted if it matches either, so listing both covers
          # whichever form the gateway actually stamps on forwarded requests.
          workload_identities = [aws_bedrockagentcore_gateway.api.gateway_id]

          hosting_environment {
            arn = aws_bedrockagentcore_gateway.api.gateway_arn
          }
        }
      }
    }
  }

  # Pass the caller's token through to the agent so it can present the same
  # identity to ACGW-MCP. Without this the agent cannot see the header.
  request_header_configuration {
    request_header_allowlist = ["Authorization"]
  }

  environment_variables = {
    ACGW_MCP_URL    = aws_bedrockagentcore_gateway.mcp.gateway_url
    AGENT_MODEL_ID  = var.agent_model_id
    AGENT_MEMORY_ID = aws_bedrockagentcore_memory.conversations.id
  }

  # Bound so a forgotten browser tab cannot hold a session open indefinitely.
  lifecycle_configuration = [{
    idle_runtime_session_timeout = var.runtime_idle_timeout_seconds
    max_lifetime                 = var.runtime_max_lifetime_seconds
  }]

  # The code object is ordered by the version_id reference above; only the
  # policy needs stating, since nothing here refers to it.
  depends_on = [aws_iam_role_policy.runtime]
}
