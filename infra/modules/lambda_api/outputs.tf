output "function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "Lambda function ARN."
  value       = aws_lambda_function.this.arn
}

output "execution_role_arn" {
  description = "Lambda execution role ARN."
  value       = aws_iam_role.lambda.arn
}

output "security_group_id" {
  description = "Lambda security group ID."
  value       = aws_security_group.lambda.id
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
  description = "CloudWatch log group for the Lambda."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "api_log_group_name" {
  description = "CloudWatch log group for the API GW access logs."
  value       = aws_cloudwatch_log_group.api.name
}

output "dlq_arn" {
  description = "Dead-letter SQS queue ARN."
  value       = aws_sqs_queue.dlq.arn
}
