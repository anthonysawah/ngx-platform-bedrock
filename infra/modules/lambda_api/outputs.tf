output "function_name" {
  description = "API Lambda function name."
  value       = aws_lambda_function.api.function_name
}

output "function_arn" {
  description = "API Lambda function ARN."
  value       = aws_lambda_function.api.arn
}

output "executor_function_name" {
  description = "Executor Lambda function name (in VPC, no internet)."
  value       = aws_lambda_function.executor.function_name
}

output "executor_log_group_name" {
  description = "CloudWatch log group for the executor Lambda."
  value       = aws_cloudwatch_log_group.executor_lambda.name
}

output "execution_role_arn" {
  description = "API Lambda execution role ARN."
  value       = aws_iam_role.api.arn
}

output "security_group_id" {
  description = "Executor Lambda security group ID."
  value       = aws_security_group.executor.id
}

output "api_id" {
  description = "API Gateway HTTP API ID."
  value       = aws_apigatewayv2_api.this.id
}

output "api_endpoint" {
  description = "Invoke URL for the API ($default stage)."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "api_execution_arn" {
  description = "Execution ARN root used by the api-gw → lambda invoke permission."
  value       = aws_apigatewayv2_api.this.execution_arn
}

output "log_group_name" {
  description = "CloudWatch log group for the API Lambda."
  value       = aws_cloudwatch_log_group.api_lambda.name
}

output "api_log_group_name" {
  description = "CloudWatch log group for the API GW access logs."
  value       = aws_cloudwatch_log_group.api.name
}

output "dlq_arn" {
  description = "Dead-letter SQS queue ARN."
  value       = aws_sqs_queue.dlq.arn
}
