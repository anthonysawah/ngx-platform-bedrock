variable "name_prefix" {
  type        = string
  description = "Prefix used for the function name and tags."
}

variable "vpc_id" {
  type        = string
  description = "VPC the Lambda SG lives in."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets the Lambda runs in."

  validation {
    condition     = length(var.private_subnet_ids) >= 1
    error_message = "Need at least one private subnet for the Lambda."
  }
}

variable "lambda_zip_path" {
  type        = string
  description = "Local filesystem path to the Lambda zip artifact."
}

variable "memory_mb" {
  type        = number
  description = "Lambda memory size in MB. 1024 leaves room for psycopg+boto3+fastapi cold start; tune later via metrics."
  default     = 1024
}

variable "timeout_seconds" {
  type        = number
  description = "Lambda timeout. Async self-invoked workloads run in this same function (ADR-012); 600s gives 10min headroom for the 5..180s schema cap plus Bedrock + DDB overhead."
  default     = 600

  validation {
    condition     = var.timeout_seconds <= 900
    error_message = "Lambda timeout maximum is 900 seconds."
  }
}

variable "reserved_concurrency" {
  type        = number
  description = <<-EOT
    Reserved concurrent executions, or -1 for no reservation (AWS default).

    Defaults to -1 because this AWS account's total Lambda concurrency limit
    is 10 (new accounts are throttled below the usual 1000 until AWS raises
    it). AWS rejects any reservation that would drop UnreservedConcurrentExecutions
    below 10, so on a 10-limit account *no* positive reservation is possible.
    Checkov CKV_AWS_115 wants a reservation here; skipped with this reason.

    Set a positive value once the account limit is raised.
  EOT
  default     = -1

  validation {
    condition     = var.reserved_concurrency == -1 || var.reserved_concurrency >= 1
    error_message = "reserved_concurrency must be -1 (no reservation) or >= 1."
  }
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention for both Lambda and API GW access logs."
  default     = 14
}

# IAM scoping inputs — every wildcard-eligible action targets a specific ARN.
# See DECISIONS.md ADR-004 (managed VPC ENI policy) and ADR-006 (action-level
# wildcards for describe-* and X-Ray, both AWS IAM limitations).

variable "aurora_secret_arn" {
  type        = string
  description = "Secrets Manager ARN for the Aurora master credentials."
}

variable "aurora_security_group_id" {
  type        = string
  description = "Aurora SG. Module emits an aws_security_group_rule allowing 5432 ingress from the Lambda SG into this SG."
}

variable "aurora_cluster_resource_id" {
  type        = string
  description = "Aurora cluster resource ID (cluster-XXXX...). Used to scope the rds-db:connect ARN for IAM database authentication."
}

variable "aurora_iam_db_user" {
  type        = string
  description = "Database role granted rds_iam. Deliberately NOT the master user — granting rds_iam disables password auth for that role, which would remove break-glass access."
  default     = "workload_app"
}

variable "aurora_cluster_arn" {
  type        = string
  description = "Aurora cluster ARN. Used for tagging; rds:DescribeDBClusters does not honor resource ARN (ADR-006)."
}

variable "ssm_path_prefix" {
  type        = string
  description = "SSM path prefix for project parameters, e.g. /dev/ai-workload-lab. IAM allows ssm:GetParameter* on '<prefix>/*'."

  validation {
    condition     = can(regex("^/[a-zA-Z0-9_./-]+$", var.ssm_path_prefix))
    error_message = "ssm_path_prefix must start with '/' and contain only valid SSM path characters."
  }
}

variable "bedrock_inference_profile_arn" {
  type        = string
  description = "Bedrock inference profile ARN."
}

variable "bedrock_foundation_model_arns" {
  type        = list(string)
  description = "Foundation model ARNs the inference profile may route to. For us.* profiles list the model in each US region (us-east-1, us-east-2, us-west-2)."
}

variable "dynamodb_table_arn" {
  type        = string
  description = "DynamoDB table ARN."
}

variable "dynamodb_gsi_arns" {
  type        = list(string)
  description = "ARNs of GSIs the Lambda must Query."
  default     = []
}

variable "environment_variables" {
  type        = map(string)
  description = "Lambda environment variables. Composed by env from module outputs + SSM parameter values."
  default     = {}
}

variable "cors_allow_origins" {
  type        = list(string)
  description = "Allowed Origin headers for the HTTP API CORS config. Default empty (no CORS); env composition passes the CloudFront domain in once static_site is created."
  default     = []
}
