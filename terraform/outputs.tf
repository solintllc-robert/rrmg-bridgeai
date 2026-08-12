output "mock_api_base_url" {
  description = "Invoke URL for the mock customer directory API. Requires SigV4 (execute-api) auth."
  value       = aws_api_gateway_stage.mock_api.invoke_url
}

output "mock_api_execution_arn" {
  description = "Execution ARN of the mock API, for granting execute-api:Invoke to ACGW-MCP."
  value       = aws_api_gateway_rest_api.mock_api.execution_arn
}

output "artifacts_bucket" {
  description = "Bucket holding the OpenAPI spec and agent code artifacts."
  value       = aws_s3_bucket.artifacts.id
}

output "openapi_spec_s3_uri" {
  description = "S3 URI of the OpenAPI spec that ACGW-MCP reads to generate tools."
  value       = "s3://${aws_s3_bucket.artifacts.id}/${aws_s3_object.openapi_spec.key}"
}

# --- Cognito -----------------------------------------------------------------

output "cognito_user_pool_id" {
  description = "Cognito user pool holding the test users."
  value       = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  description = "App client id. JWT authorizers validate this against the token's client_id claim."
  value       = aws_cognito_user_pool_client.web.id
}

output "cognito_discovery_url" {
  description = "OIDC discovery document used by every JWT authorizer in the stack."
  value       = local.cognito_discovery_url
}

output "cognito_hosted_ui_domain" {
  description = "Hosted UI domain that serves the sign-in page."
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "admin_user_password" {
  description = "Generated password for the customer-admin test user."
  value       = random_password.admin_user.result
  sensitive   = true
}

output "support_user_password" {
  description = "Generated password for the customer-support test user."
  value       = random_password.support_user.result
  sensitive   = true
}

# --- ACGW-MCP ----------------------------------------------------------------

output "acgw_mcp_gateway_id" {
  description = "Id of the tools gateway."
  value       = aws_bedrockagentcore_gateway.mcp.gateway_id
}

output "acgw_mcp_url" {
  description = "MCP endpoint the agent connects to for tools."
  value       = aws_bedrockagentcore_gateway.mcp.gateway_url
}

output "acgw_mcp_role_arn" {
  description = "Execution role ACGW-MCP uses to read the spec and sign calls to the mock API."
  value       = aws_iam_role.gateway_mcp.arn
}

# --- Agent runtime -----------------------------------------------------------

output "agent_runtime_arn" {
  description = "ARN of the deployed agent runtime."
  value       = aws_bedrockagentcore_agent_runtime.agent.agent_runtime_arn
}

output "agent_runtime_id" {
  description = "Id of the deployed agent runtime."
  value       = aws_bedrockagentcore_agent_runtime.agent.agent_runtime_id
}

# --- ACGW-API ----------------------------------------------------------------

output "acgw_api_url" {
  description = "Front-door gateway URL. CloudFront proxies /api to this."
  value       = aws_bedrockagentcore_gateway.api.gateway_url
}

output "acgw_api_gateway_arn" {
  description = "ARN of the front-door gateway."
  value       = aws_bedrockagentcore_gateway.api.gateway_arn
}

output "acgw_api_target_name" {
  description = "Target name segment in the invoke path."
  value       = var.acgw_api_target_name
}

# --- Edge --------------------------------------------------------------------

output "site_url" {
  description = "Public URL of the assistant."
  value       = "https://${aws_cloudfront_distribution.web.domain_name}"
}

output "docs_url" {
  description = "Public URL of the API documentation."
  value       = "https://${aws_cloudfront_distribution.web.domain_name}/docs.html"
}

output "web_bucket" {
  description = "Bucket holding the built site."
  value       = aws_s3_bucket.web.id
}

output "cloudfront_distribution_id" {
  description = "Distribution id, needed to invalidate the cache after a deploy."
  value       = aws_cloudfront_distribution.web.id
}
