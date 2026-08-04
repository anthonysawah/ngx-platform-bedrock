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

variable "alarm_email" {
  type        = string
  description = "Email subscriber for CloudWatch alarms. Empty disables the subscription (topic still exists)."
  default     = ""
  sensitive   = true
}

variable "enable_internet_egress" {
  type        = bool
  description = <<-EOT
    Break-glass toggle (ADR-013). true restores the IGW + public subnets +
    NAT gateway AND grants the executor SG temporary 443 egress to
    0.0.0.0/0 so it can reach Secrets Manager for the one-time
    {"_ngx_bootstrap": true} rds_iam grant. Both halves are required —
    NAT alone is not enough, because the executor SG's only 443 egress
    normally targets the S3/DynamoDB gateway-endpoint prefix lists.
    Flip back to false immediately after bootstrapping.
  EOT
  default     = false
}
