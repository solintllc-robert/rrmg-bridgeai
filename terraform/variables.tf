variable "aws_region" {
  description = "Region for every resource in the stack."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to resource names. Lowercase and hyphenated so it is safe in S3 bucket names."
  type        = string
  default     = "rrmg-bridgeai"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.name_prefix))
    error_message = "name_prefix must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "iam_role_path" {
  description = "Path for the stack's execution roles. The account only permits role creation under /bridge-ai/, so this is not free to change."
  type        = string
  default     = "/bridge-ai/"
}

variable "tags" {
  description = "Tags applied to every resource in the stack."
  type        = map(string)
  default = {
    poc     = "rrmg"
    project = "bridge.ai"
  }
}

variable "api_stage_name" {
  description = "API Gateway stage name for the mock API."
  type        = string
  default     = "v1"
}

variable "admin_user_email" {
  description = "Sign-in address of the test user who may read customer home addresses."
  type        = string
  default     = "customer.admin@example.com"
}

variable "support_user_email" {
  description = "Sign-in address of the test user who may not read customer home addresses."
  type        = string
  default     = "customer.support@example.com"
}

variable "local_web_origin" {
  description = "Origin of the local development server, allowed as a Cognito redirect target while building."
  type        = string
  default     = "http://localhost:5173"
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the stack's log groups."
  type        = number
  default     = 14
}

variable "agent_model_id" {
  description = "Bedrock model the agent uses. Requires model access to be enabled in the Bedrock console."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "runtime_idle_timeout_seconds" {
  description = "How long an idle agent session survives before the runtime ends it."
  type        = number
  default     = 900
}

variable "runtime_max_lifetime_seconds" {
  description = "Hard ceiling on any single agent session, regardless of activity."
  type        = number
  default     = 3600
}

variable "acgw_api_target_name" {
  description = "Target name on ACGW-API. Appears in the invoke path, so it is part of the public URL."
  type        = string
  default     = "api"
}

variable "restrict_runtime_to_gateway" {
  description = "When true, the runtime accepts invocations only through ACGW-API. Applied after the runtime is confirmed working."
  type        = bool
  default     = false
}

variable "mcp_target_name" {
  description = "Target name on ACGW-MCP. Tool names are prefixed with it, so Cedar policies reference it."
  type        = string
  default     = "customer-directory"
}

variable "policy_enforcement_mode" {
  description = "How ACGW-MCP applies Cedar policies. ENFORCE blocks denied calls; LOG_ONLY records them without blocking."
  type        = string
  default     = "ENFORCE"
}

variable "waf_rate_limit" {
  description = "Requests allowed from one IP in a five-minute window before the firewall blocks it."
  type        = number
  default     = 500
}

variable "deployed_web_origin" {
  description = "Public origin of the deployed site, for example https://d111.cloudfront.net. Left empty on the first apply, then supplied by scripts/deploy-web.sh once CloudFront exists."
  type        = string
  default     = ""
}
