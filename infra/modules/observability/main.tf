# Observability — SNS topic + alarms + Bedrock-usage metric filters + dashboard.
#
# Why one module: the alarms, the topic they publish to, and the dashboard
# they're surfaced on are a single concern. Splitting them adds wiring with
# no payoff at this scope.

############################
# SNS topic + email subscription
############################

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"

  tags = {
    Name = "${var.name_prefix}-alerts"
  }
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

############################
# CloudWatch metric filters — Bedrock token usage
#
# bedrock.py logs `bedrock_converse` events with input_tokens / output_tokens.
# Filter pulls those into custom CloudWatch metrics so the dashboard can chart
# Bedrock cost over time without us adding a separate metrics path.
############################

resource "aws_cloudwatch_log_metric_filter" "bedrock_input_tokens" {
  name           = "${var.name_prefix}-bedrock-input-tokens"
  log_group_name = var.lambda_log_group_name

  pattern = "{ $.message = \"bedrock_converse\" && $.input_tokens > 0 }"

  metric_transformation {
    name      = "BedrockInputTokens"
    namespace = "ngx-workload-lab"
    value     = "$.input_tokens"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "bedrock_output_tokens" {
  name           = "${var.name_prefix}-bedrock-output-tokens"
  log_group_name = var.lambda_log_group_name

  pattern = "{ $.message = \"bedrock_converse\" && $.output_tokens > 0 }"

  metric_transformation {
    name      = "BedrockOutputTokens"
    namespace = "ngx-workload-lab"
    value     = "$.output_tokens"
    unit      = "Count"
  }
}

############################
# Alarms — Lambda errors
############################

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.name_prefix}-lambda-errors"
  alarm_description   = "Lambda function errors >= 1 in any 5-minute window."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

############################
# Alarms — Aurora ACU at max
############################

resource "aws_cloudwatch_metric_alarm" "aurora_acu_at_max" {
  alarm_name          = "${var.name_prefix}-aurora-acu-at-max"
  alarm_description   = "Aurora ServerlessDatabaseCapacity at configured max for >= 2 minutes — capacity ceiling reached."
  namespace           = "AWS/RDS"
  metric_name         = "ServerlessDatabaseCapacity"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.aurora_max_capacity
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = var.aurora_cluster_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

############################
# Alarms — DynamoDB throttled requests
############################

resource "aws_cloudwatch_metric_alarm" "dynamodb_throttled" {
  alarm_name          = "${var.name_prefix}-ddb-throttled"
  alarm_description   = "DynamoDB throttled any request in the last 5 minutes — on-demand capacity is being rejected."
  namespace           = "AWS/DynamoDB"
  metric_name         = "ThrottledRequests"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = var.dynamodb_table_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

############################
# Alarms — API Gateway 5xx
############################

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.name_prefix}-api-5xx"
  alarm_description   = "API Gateway returning 5xx — Lambda hit an unhandled exception or timeout."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_gateway_id
    Stage = var.api_gateway_stage
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

############################
# Dashboard
############################

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Lambda — invocations & errors"
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.lambda_function_name],
            [".", "Errors", ".", ".", { color = "#d62728" }],
            [".", "Throttles", ".", ".", { color = "#ff7f0e" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Lambda — duration (p50 / p95 / max)"
          view   = "timeSeries"
          period = 60
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", var.lambda_function_name, { stat = "p50" }],
            ["...", { stat = "p95", color = "#ff7f0e" }],
            ["...", { stat = "Maximum", color = "#d62728" }],
          ]
          yAxis = { left = { min = 0, label = "ms" } }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Aurora — Serverless v2 ACU"
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "ServerlessDatabaseCapacity", "DBClusterIdentifier", var.aurora_cluster_identifier],
          ]
          annotations = {
            horizontal = [
              { label = "Max ACU", value = var.aurora_max_capacity, color = "#d62728" }
            ]
          }
          yAxis = { left = { min = 0, label = "ACU" } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Aurora — CPU & connections"
          view   = "timeSeries"
          period = 60
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", var.aurora_cluster_identifier, { stat = "Average", yAxis = "left" }],
            [".", "DatabaseConnections", ".", ".", { stat = "Average", yAxis = "right" }],
          ]
          yAxis = {
            left  = { min = 0, max = 100, label = "CPU %" }
            right = { min = 0, label = "Connections" }
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "DynamoDB — capacity & throttles"
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          region = var.aws_region
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.dynamodb_table_name],
            [".", "ConsumedWriteCapacityUnits", ".", "."],
            [".", "ThrottledRequests", ".", ".", { color = "#d62728" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway — request volume & errors"
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          region = var.aws_region
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", var.api_gateway_id, "Stage", var.api_gateway_stage],
            [".", "4xx", ".", ".", ".", ".", { color = "#ff7f0e" }],
            [".", "5xx", ".", ".", ".", ".", { color = "#d62728" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 24
        height = 6
        properties = {
          title  = "Bedrock token usage (input / output) — from log metric filter"
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          region = var.aws_region
          metrics = [
            ["ngx-workload-lab", "BedrockInputTokens"],
            [".", "BedrockOutputTokens", { color = "#ff7f0e" }],
          ]
        }
      },
    ]
  })
}
