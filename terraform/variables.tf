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

variable "log_retention_days" {
  description = "CloudWatch log retention for the stack's log groups."
  type        = number
  default     = 14
}
