output "table_name" {
  description = "DynamoDB table name."
  value       = aws_dynamodb_table.this.name
}

output "table_arn" {
  description = "DynamoDB table ARN. Used for IAM dynamodb:PutItem / Query on the table."
  value       = aws_dynamodb_table.this.arn
}

output "gsi_arn" {
  description = "ARN of the status-created_at GSI. IAM dynamodb:Query for the 'last N runs' lookup must include this."
  value       = "${aws_dynamodb_table.this.arn}/index/status-created_at"
}
