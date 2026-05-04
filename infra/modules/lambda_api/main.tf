# Lambda + API Gateway HTTP API with least-privilege IAM.
#
# Security group topology
#   Lambda SG  → egress 5432 to Aurora SG (declared here, applied to lambda SG)
#   Lambda SG  → egress 443 to 0.0.0.0/0 (NAT-bound AWS API calls; ADR-005)
#   Aurora SG  ← ingress 5432 from Lambda SG (declared here, applied to aurora SG)
#
# Hosting the cross-SG ingress rule in this module — rather than in the env
# composition — is fine because lambda_api consumes aurora's SG output, not
# the other way around. No cycle.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  function_name = "${var.name_prefix}-api"
  log_group     = "/aws/lambda/${local.function_name}"
  api_log_group = "/aws/apigw/${local.function_name}"
  dlq_name      = "${var.name_prefix}-api-dlq"
}

############################
# Security groups + rules
############################

resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda"
  description = "Lambda SG. Egress to Aurora 5432 + 443 to AWS APIs via NAT."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-lambda"
  }
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_aurora" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "Aurora Postgres"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.aurora_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "lambda_https_anywhere" {
  security_group_id = aws_security_group.lambda.id
  description       = "AWS API egress via NAT (SSM, Secrets Manager, Bedrock). VPC interface endpoints are v1.5 (ADR-005)."
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "aurora_from_lambda" {
  security_group_id            = var.aurora_security_group_id
  description                  = "Aurora Postgres from Lambda SG only."
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.lambda.id
}

############################
# Log groups
############################

resource "aws_cloudwatch_log_group" "lambda" {
  name              = local.log_group
  retention_in_days = var.log_retention_days

  tags = {
    Name = local.log_group
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = local.api_log_group
  retention_in_days = var.log_retention_days

  tags = {
    Name = local.api_log_group
  }
}

############################
# Dead-letter queue
############################

resource "aws_sqs_queue" "dlq" {
  name                       = local.dlq_name
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 60
  sqs_managed_sse_enabled    = true

  tags = {
    Name = local.dlq_name
  }
}

############################
# IAM execution role
############################

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-api-execution"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  description        = "Execution role for ${local.function_name}."
}

# AWS-managed VPC ENI policy. The single deviation from "no managed policies",
# documented in DECISIONS.md ADR-004.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "lambda_inline" {
  # Logs — scoped to this function's log group only.
  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  # SSM — read parameters under the project prefix only.
  statement {
    sid    = "ReadProjectSsmParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_path_prefix}/*",
    ]
  }

  # Secrets Manager — only the Aurora master secret.
  statement {
    sid    = "ReadAuroraMasterSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [var.aurora_secret_arn]
  }

  # Bedrock — inference profile + the underlying foundation model ARNs the
  # profile may route to. Per AWS docs for cross-region inference profiles,
  # both are required.
  statement {
    sid    = "InvokeBedrock"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:Converse",
      "bedrock:ConverseStream",
    ]
    resources = concat(
      [var.bedrock_inference_profile_arn],
      var.bedrock_foundation_model_arns,
    )
  }

  # DynamoDB — read/write the runs table + Query the GSI. BatchWriteItem
  # is what boto3's table.batch_writer() uses to flush per-second metrics.
  statement {
    sid    = "DynamoDbTableAccess"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:DescribeTable",
      "dynamodb:BatchWriteItem",
    ]
    resources = concat([var.dynamodb_table_arn], var.dynamodb_gsi_arns)
  }

  # SQS — write to own DLQ only.
  statement {
    sid    = "PublishToDlq"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.dlq.arn]
  }

  # rds:DescribeDBClusters does not support resource-level permissions; the
  # IAM action requires Resource:"*". Application code is constrained to
  # filter by our cluster ID. Documented in ADR-006.
  statement {
    sid    = "RdsDescribeAcuLimitation"
    effect = "Allow"
    actions = [
      "rds:DescribeDBClusters",
    ]
    resources = ["*"]
  }

  # X-Ray actions also do not support resource-level permissions. ADR-006.
  statement {
    sid    = "XrayTraceWrite"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    resources = ["*"]
  }

  # CloudWatch GetMetricData is the only way to read real-time
  # ServerlessDatabaseCapacity (ACU). The action does not support
  # resource-level permissions; documented in ADR-006.
  statement {
    sid    = "CloudwatchAcuMetricRead"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
    ]
    resources = ["*"]
  }

  # Self async-invoke for the workload runner path (ADR-012). The ARN is
  # constructed from the known function name to avoid a circular dep on
  # the function resource (the function's role depends on this policy).
  statement {
    sid    = "AsyncInvokeSelf"
    effect = "Allow"
    actions = [
      "lambda:InvokeFunction",
    ]
    resources = [
      "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:${local.function_name}",
    ]
  }
}

resource "aws_iam_role_policy" "lambda_inline" {
  name   = "${var.name_prefix}-api-inline"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_inline.json
}

############################
# Lambda function
############################

resource "aws_lambda_function" "this" {
  function_name = local.function_name
  description   = "ngx-workload-lab API: intent parser + workload executor + summary."
  role          = aws_iam_role.lambda.arn

  package_type     = "Zip"
  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  handler       = "ngx_workload_lab.main.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]

  memory_size = var.memory_mb
  timeout     = var.timeout_seconds

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  environment {
    variables = var.environment_variables
  }

  depends_on = [
    aws_iam_role_policy.lambda_inline,
    aws_iam_role_policy_attachment.vpc_access,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = {
    Name = local.function_name
  }
}

############################
# HTTP API + integration + routes + stage
############################

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
  description   = "HTTP API fronting the ngx-workload-lab Lambda."

  dynamic "cors_configuration" {
    for_each = length(var.cors_allow_origins) > 0 ? [1] : []
    content {
      allow_origins  = var.cors_allow_origins
      allow_methods  = ["GET", "POST", "OPTIONS"]
      allow_headers  = ["content-type", "x-request-id", "authorization"]
      expose_headers = ["x-request-id"]
      max_age        = 600
    }
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.this.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      protocol                = "$context.protocol"
      responseLatency         = "$context.responseLatency"
      ip                      = "$context.identity.sourceIp"
      userAgent               = "$context.identity.userAgent"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowExecutionFromApiGw"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
