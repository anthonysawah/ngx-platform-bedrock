output "sns_topic_arn" {
  description = "SNS topic the alarms publish to."
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "dashboard_url" {
  description = "Direct URL to the dashboard in the AWS console."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "alarm_names" {
  description = "Names of the alarms in this module."
  value = [
    aws_cloudwatch_metric_alarm.lambda_errors.alarm_name,
    aws_cloudwatch_metric_alarm.aurora_acu_at_max.alarm_name,
    aws_cloudwatch_metric_alarm.dynamodb_throttled.alarm_name,
    aws_cloudwatch_metric_alarm.api_5xx.alarm_name,
  ]
}
