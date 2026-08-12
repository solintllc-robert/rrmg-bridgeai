# ---------------------------------------------------------------------------
# Authorization on ACGW-MCP
#
# This is where "who is allowed to see what" is actually decided. It is
# deliberately outside the agent: the model is told about the rules in its
# system prompt, but the model is not what enforces them. If the agent were
# talked into trying to read a home address for a user who may not see one,
# the call is refused here and never reaches the API.
#
# The engine is default-deny. Every tool needs an explicit permit, so adding a
# new endpoint to the API without adding a policy leaves it unreachable rather
# than silently open.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_policy_engine" "main" {
  name        = replace("${var.name_prefix}_policy_engine", "-", "_")
  description = "Authorization rules for customer directory tools."
}


# Everything that is not personal information: available to any signed-in user.
resource "aws_bedrockagentcore_policy" "directory_read" {
  name             = "allow_directory_lookups"
  description      = "Any authenticated user may search the directory and read non-personal customer details."
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id

  definition {
    cedar {
      statement = <<-CEDAR
        permit(
          principal is AgentCore::OAuthUser,
          action in [
            AgentCore::Action::"${var.mcp_target_name}___searchCustomers",
            AgentCore::Action::"${var.mcp_target_name}___getCustomer",
            AgentCore::Action::"${var.mcp_target_name}___getCustomerWorkAddress"
          ],
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.mcp.gateway_arn}"
        );
      CEDAR
    }
  }
}

# Home addresses: only for members of the customer-admin group. The group comes
# from the caller's token, which the gateway has already verified.
#
# The group list arrives as a single string rather than a list, so this matches
# on substring. That is safe only while no group name is contained inside
# another group name - if a group like "customer-admin-readonly" is ever added,
# this test would match it too and must be tightened.
resource "aws_bedrockagentcore_policy" "home_address" {
  name             = "allow_home_address_for_admins"
  description      = "Only members of customer-admin may read a customer's home address."
  policy_engine_id = aws_bedrockagentcore_policy_engine.main.policy_engine_id

  definition {
    cedar {
      statement = <<-CEDAR
        permit(
          principal is AgentCore::OAuthUser,
          action == AgentCore::Action::"${var.mcp_target_name}___getCustomerHomeAddress",
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.mcp.gateway_arn}"
        )
        when {
          principal.hasTag("cognito:groups") &&
          principal.getTag("cognito:groups") like "*${aws_cognito_user_group.customer_admin.name}*"
        };
      CEDAR
    }
  }
}
