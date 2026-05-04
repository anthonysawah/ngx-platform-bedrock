output "vpc_id" {
  description = "ID of the VPC for this environment."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "Primary CIDR block of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs (Lambda + Aurora live here)."
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs (NAT lives here; nothing else by design)."
  value       = module.vpc.public_subnet_ids
}

output "availability_zones" {
  description = "AZs the subnets are placed in."
  value       = module.vpc.availability_zones
}

output "aurora_cluster_identifier" {
  description = "Aurora cluster identifier (input for describe-db-clusters ACU sampling)."
  value       = module.aurora.cluster_identifier
}

output "aurora_cluster_endpoint" {
  description = "Writer endpoint hostname for the Aurora cluster."
  value       = module.aurora.cluster_endpoint
}

output "aurora_master_secret_arn" {
  description = "Secrets Manager ARN holding master credentials JSON."
  value       = module.aurora.master_user_secret_arn
}

output "aurora_security_group_id" {
  description = "Aurora SG. Lambda module ingresses from lambda SG → 5432 here."
  value       = module.aurora.security_group_id
}

output "dynamodb_table_name" {
  description = "DynamoDB table holding run headers + per-second metric samples."
  value       = module.dynamodb.table_name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN."
  value       = module.dynamodb.table_arn
}

output "api_endpoint" {
  description = "Invoke URL for the HTTP API. Append /health, /workloads, etc."
  value       = module.lambda_api.api_endpoint
}

output "lambda_function_name" {
  description = "Lambda function name (handy for awslogs tail)."
  value       = module.lambda_api.function_name
}

output "lambda_log_group" {
  description = "CloudWatch log group for the Lambda."
  value       = module.lambda_api.log_group_name
}

output "ssm_path_prefix" {
  description = "SSM path prefix for project parameters."
  value       = local.ssm_prefix
}
