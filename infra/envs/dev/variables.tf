variable "aws_region" {
  type        = string
  description = "AWS region this environment is deployed to."
  default     = "us-east-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-\\d$", var.aws_region))
    error_message = "aws_region must be a valid AWS region code (e.g., us-east-2)."
  }
}

variable "environment" {
  type        = string
  description = "Environment name. v1 deploys only 'dev'."
  default     = "dev"

  validation {
    condition     = contains(["dev"], var.environment)
    error_message = "Only 'dev' is supported in v1. Multi-env is a v1.5 item; see DECISIONS.md."
  }
}

variable "project" {
  type        = string
  description = "Project tag and resource-name prefix."
  default     = "ai-workload-lab"
}
