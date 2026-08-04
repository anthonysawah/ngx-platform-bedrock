# Two Lambdas, split by network requirement (ADR-013).
#
#   api       OUTSIDE the VPC. HTTP API integration, Bedrock, SSM, DynamoDB,
#             CloudWatch. Reaches AWS over the public internet like any other
#             client, so it needs no NAT and no interface endpoints.
#
#   executor  INSIDE the VPC, in private subnets, with NO egress rule to the
#             internet at all. Its only outbound rule is 5432 to the Aurora
#             SG. Reaches DynamoDB over the free gateway endpoint and
#             authenticates to Postgres with a locally-signed IAM token.
#
# That split is what allowed the NAT gateway and its Elastic IP to be
# deleted -- $36/mo of a measured ~$82/mo bill, billed hourly regardless of traffic.
#
# Both functions ship the same zip and differ only in handler entrypoint.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  api_function_name      = "${var.name_prefix}-api"
  executor_function_name = "${var.name_prefix}-executor"
  api_log_group          = "/aws/lambda/${var.name_prefix}-api"
  executor_log_group     = "/aws/lambda/${var.name_prefix}-executor"
  apigw_log_group        = "/aws/apigw/${var.name_prefix}-api"
  dlq_name               = "${var.name_prefix}-api-dlq"

  executor_arn = "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:${local.executor_function_name}"
}

# The API Lambda kept its identity across the split; only its role and
# network config changed. Renaming without these would destroy and recreate
# the function, churning the API Gateway integration for no reason.
moved {
  from = aws_lambda_function.this
  to   = aws_lambda_function.api
}

moved {
  from = aws_iam_role.lambda
  to   = aws_iam_role.api
}

moved {
  from = aws_iam_role_policy.lambda_inline
  to   = aws_iam_role_policy.api
}

moved {
  from = aws_cloudwatch_log_group.lambda
  to   = aws_cloudwatch_log_group.api_lambda
}

moved {
  from = aws_security_group.lambda
  to   = aws_security_group.executor
}

############################
# Security group — executor only
############################

# No egress rule to 0.0.0.0/0. The executor is deliberately unable to reach
# the internet; if a future dependency needs it, that should be an explicit,
# reviewed change rather than something it silently already had.
resource "aws_security_group" "executor" {
  name        = "${var.name_prefix}-executor"
  description = "Executor Lambda SG. Egress to Aurora 5432 only; no internet path."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-executor"
  }
}

resource "aws_vpc_security_group_egress_rule" "executor_to_aurora" {
  security_group_id            = aws_security_group.executor.id
  description                  = "Aurora Postgres"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.aurora_security_group_id
}

# Gateway endpoints are route-table based, but egress still passes through
# the SG. Without these rules the executor cannot reach DynamoDB at all --
# which is exactly how this broke the first time. Scoped to the managed
# prefix lists, so this grants AWS-service reachability, not internet access.
resource "aws_vpc_security_group_egress_rule" "executor_to_gateway_endpoints" {
  count = length(var.gateway_endpoint_prefix_list_ids)

  security_group_id = aws_security_group.executor.id
  description       = "S3/DynamoDB gateway endpoint (prefix list ${count.index})"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = var.gateway_endpoint_prefix_list_ids[count.index]
}

# Break-glass only (ADR-013): exists solely while enable_bootstrap_egress
# is true, so the {"_ngx_bootstrap": true} invoke can reach Secrets Manager
# via the temporarily-restored NAT. Destroyed again when the toggle flips off.
resource "aws_vpc_security_group_egress_rule" "executor_bootstrap_https" {
  count = var.enable_bootstrap_egress ? 1 : 0

  security_group_id = aws_security_group.executor.id
  description       = "TEMPORARY break-glass egress for IAM bootstrap (Secrets Manager via NAT)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "aurora_from_executor" {
  security_group_id            = var.aurora_security_group_id
  description                  = "Aurora Postgres from executor Lambda SG only."
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.executor.id
}

############################
# Log groups
############################

resource "aws_cloudwatch_log_group" "api_lambda" {
  name              = local.api_log_group
  retention_in_days = var.log_retention_days
  tags              = { Name = local.api_log_group }
}

resource "aws_cloudwatch_log_group" "executor_lambda" {
  name              = local.executor_log_group
  retention_in_days = var.log_retention_days
  tags              = { Name = local.executor_log_group }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = local.apigw_log_group
  retention_in_days = var.log_retention_days
  tags              = { Name = local.apigw_log_group }
}

############################
# Dead-letter queue (API only)
############################

# Only the API Lambda gets a DLQ. SQS has no gateway endpoint, so wiring one
# to the executor would reintroduce the internet dependency we just removed.
# The executor's real error surface is the RunRecord it writes with
# status = "workload_error", which the UI surfaces directly.
resource "aws_sqs_queue" "dlq" {
  name                       = local.dlq_name
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 60
  sqs_managed_sse_enabled    = true
  tags                       = { Name = local.dlq_name }
}

############################
# Shared assume-role policy
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

############################
# API Lambda — role + policy
############################

resource "aws_iam_role" "api" {
  name               = "${var.name_prefix}-api-execution"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  description        = "Execution role for ${local.api_function_name} (outside VPC)."
}

data "aws_iam_policy_document" "api" {
  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api_lambda.arn}:*"]
  }

  statement {
    sid     = "ReadProjectSsmParameters"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_path_prefix}/*",
    ]
  }

  # Bedrock — inference profile plus the foundation model ARNs it may route
  # to. Cross-region inference profiles require both.
  statement {
    sid     = "InvokeBedrock"
    effect  = "Allow"
    actions = ["bedrock:InvokeModel", "bedrock:Converse", "bedrock:ConverseStream"]
    resources = concat(
      [var.bedrock_inference_profile_arn],
      var.bedrock_foundation_model_arns,
    )
  }

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

  statement {
    sid       = "PublishToDlq"
    effect    = "Allow"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.dlq.arn]
  }

  # Kick off workloads. Scoped to the executor function's ARN, built from its
  # known name to avoid a dependency cycle on the function resource.
  statement {
    sid       = "InvokeExecutor"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.executor_arn]
  }

  # rds:DescribeDBClusters, CloudWatch metric reads and X-Ray all lack
  # resource-level permissions in IAM. Documented in ADR-006.
  statement {
    sid       = "ObservabilityReadsWithoutResourceScoping"
    effect    = "Allow"
    actions   = ["rds:DescribeDBClusters", "cloudwatch:GetMetricData", "xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "${var.name_prefix}-api-inline"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

############################
# Executor Lambda — role + policy
############################

resource "aws_iam_role" "executor" {
  name               = "${var.name_prefix}-executor-execution"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  description        = "Execution role for ${local.executor_function_name} (in VPC, no internet)."
}

# ENI lifecycle for the in-VPC function. The one AWS-managed policy this
# project accepts; rationale in ADR-004.
resource "aws_iam_role_policy_attachment" "executor_vpc_access" {
  role       = aws_iam_role.executor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "executor" {
  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.executor_lambda.arn}:*"]
  }

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

  # IAM database authentication, scoped to one cluster and one DB user --
  # as tight as rds-db:connect gets. The token is minted by local SigV4
  # signing, which is why this function needs no network path to AWS.
  statement {
    sid       = "RdsIamDbConnect"
    effect    = "Allow"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:${var.aurora_cluster_resource_id}/${var.aurora_iam_db_user}"]
  }

  # Break-glass only: re-running the rds_iam grant needs the master password.
  # The executor cannot actually reach Secrets Manager without temporary
  # egress; the permission is here so the recovery path is a network change
  # rather than also an IAM change. See ADR-013.
  statement {
    sid       = "ReadAuroraMasterSecretForBootstrap"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.aurora_secret_arn]
  }
}

resource "aws_iam_role_policy" "executor" {
  name   = "${var.name_prefix}-executor-inline"
  role   = aws_iam_role.executor.id
  policy = data.aws_iam_policy_document.executor.json
}

############################
# Functions
############################

resource "aws_lambda_function" "api" {
  function_name = local.api_function_name
  description   = "ngx-workload-lab API: HTTP, Bedrock intent parse + summary, ACU overlay."
  role          = aws_iam_role.api.arn

  package_type     = "Zip"
  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  handler       = "ngx_workload_lab.main.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]

  memory_size = var.memory_mb
  # Short: this function only parses intent and serves polls. The long-running
  # work moved to the executor.
  timeout = var.api_timeout_seconds

  reserved_concurrent_executions = var.reserved_concurrency

  # Deliberately no vpc_config. Being outside the VPC is what removes the
  # NAT dependency and also drops ~1.6s of ENI cold-start.

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  environment {
    variables = merge(var.environment_variables, {
      EXECUTOR_FUNCTION_NAME = local.executor_function_name
    })
  }

  depends_on = [
    aws_iam_role_policy.api,
    aws_cloudwatch_log_group.api_lambda,
  ]

  tags = { Name = local.api_function_name }
}

resource "aws_lambda_function" "executor" {
  function_name = local.executor_function_name
  description   = "ngx-workload-lab executor: drives Aurora. In VPC, no internet."
  role          = aws_iam_role.executor.arn

  package_type     = "Zip"
  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  handler       = "ngx_workload_lab.executor.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]

  memory_size = var.memory_mb
  timeout     = var.timeout_seconds

  reserved_concurrent_executions = var.reserved_concurrency

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.executor.id]
  }

  # PassThrough, not Active: the X-Ray daemon posts segments over the network,
  # and this function has no egress. Active tracing here would just add
  # latency retrying calls that cannot succeed.
  tracing_config {
    mode = "PassThrough"
  }

  environment {
    variables = var.environment_variables
  }

  depends_on = [
    aws_iam_role_policy.executor,
    aws_iam_role_policy_attachment.executor_vpc_access,
    aws_cloudwatch_log_group.executor_lambda,
  ]

  tags = { Name = local.executor_function_name }
}

############################
# HTTP API + integration + routes + stage
############################

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
  description   = "HTTP API fronting the ngx-workload-lab API Lambda."

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
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  # Explicit rather than implicit-by-absence so the auth posture is
  # reviewable. v1 runs unauthenticated behind CloudFront; v1.5 adds Cognito.
  authorization_type = "NONE"
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
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
