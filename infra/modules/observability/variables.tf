variable "name_prefix" {
  type        = string
  description = "Prefix used for the SNS topic, alarms, and dashboard names."
}

variable "alarm_email" {
  type        = string
  description = "Email subscriber for alarm notifications. Empty disables the subscription (topic still exists)."
  default     = ""

  validation {
    condition     = var.alarm_email == "" || can(regex("^[^@]+@[^@]+$", var.alarm_email))
    error_message = "alarm_email must be either empty or a valid email address."
  }
}

variable "aws_region" {
  type        = string
  description = "Region the dashboard targets for metric queries."
}

variable "lambda_function_name" {
  type        = string
  description = "Lambda function name (Errors / Duration / Invocations dimensions)."
}

variable "lambda_log_group_name" {
  type        = string
  description = "Lambda log group; used by Bedrock token-usage metric filters."
}

variable "aurora_cluster_identifier" {
  type        = string
  description = "Aurora cluster identifier for ServerlessDatabaseCapacity / CPU / Connections dimensions."
}

variable "aurora_max_capacity" {
  type        = number
  description = "Aurora Serverless v2 max_capacity. Alarm fires when ACU is at this value for 2 minutes."
}

variable "dynamodb_table_name" {
  type        = string
  description = "DynamoDB table name for ConsumedCapacity / ThrottledRequests dimensions."
}

variable "api_gateway_id" {
  type        = string
  description = "API Gateway HTTP API ID."
}

variable "api_gateway_stage" {
  type        = string
  description = "API Gateway stage (HTTP API uses $default)."
  default     = "$default"
}
