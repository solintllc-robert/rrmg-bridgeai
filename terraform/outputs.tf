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
