locals {
  name_prefix = "${var.project}-${var.environment}"
  ssm_prefix  = "/${var.environment}/${var.project}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Lambda zip is built by app/scripts/build_lambda_package.sh into app/build/.
  lambda_zip_path = "${path.module}/../../../app/build/lambda.zip"

  # Bedrock cross-region inference profile + the foundation model ARNs the
  # profile may route to. Sonnet 4.6 us.* profile routes within US regions.
  bedrock_inference_profile_arn = "arn:aws:bedrock:us-east-2:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-sonnet-4-6"
  bedrock_foundation_model_arns = [
    "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6",
    "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-6",
    "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6",
  ]
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

module "vpc" {
  source = "../../modules/vpc"

  name_prefix        = local.name_prefix
  vpc_cidr           = "10.20.0.0/16"
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
  single_nat_gateway = true
}

module "aurora" {
  source = "../../modules/aurora"

  name_prefix        = local.name_prefix
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  engine_version = "15.17"
  min_capacity   = 0.5
  max_capacity   = 4
}

module "dynamodb" {
  source = "../../modules/dynamodb"

  name_prefix = local.name_prefix
}

module "static_site" {
  source = "../../modules/static_site"

  name_prefix = local.name_prefix
}

############################
# SSM parameters (config plane)
############################

# Config source-of-truth lives in SSM. Values are also passed to the Lambda
# as environment variables for fast cold-start reads. CLAUDE.md requires
# config to come from SSM/Secrets Manager — Terraform satisfies that by
# writing to SSM here, then sourcing the env var values from these resources.

resource "aws_ssm_parameter" "bedrock_model_id" {
  name        = "${local.ssm_prefix}/bedrock-model-id"
  description = "Bedrock inference profile ARN for ngx-workload-lab."
  type        = "String"
  value       = local.bedrock_inference_profile_arn
}

resource "aws_ssm_parameter" "aurora_cluster_identifier" {
  name        = "${local.ssm_prefix}/aurora-cluster-identifier"
  description = "Aurora cluster identifier (input for describe-db-clusters ACU sampling)."
  type        = "String"
  value       = module.aurora.cluster_identifier
}

resource "aws_ssm_parameter" "aurora_cluster_endpoint" {
  name        = "${local.ssm_prefix}/aurora-cluster-endpoint"
  description = "Aurora writer endpoint hostname for psycopg connections."
  type        = "String"
  value       = module.aurora.cluster_endpoint
}

resource "aws_ssm_parameter" "aurora_secret_arn" {
  name        = "${local.ssm_prefix}/aurora-secret-arn"
  description = "Secrets Manager ARN holding Aurora master credentials."
  type        = "String"
  value       = module.aurora.master_user_secret_arn
}

resource "aws_ssm_parameter" "dynamodb_table_name" {
  name        = "${local.ssm_prefix}/dynamodb-table-name"
  description = "DynamoDB table name for runs + per-second metrics."
  type        = "String"
  value       = module.dynamodb.table_name
}

############################
# Lambda + API
############################

module "lambda_api" {
  source = "../../modules/lambda_api"

  name_prefix        = local.name_prefix
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  lambda_zip_path    = local.lambda_zip_path

  aurora_secret_arn        = module.aurora.master_user_secret_arn
  aurora_security_group_id = module.aurora.security_group_id
  aurora_cluster_arn       = module.aurora.cluster_arn

  ssm_path_prefix = local.ssm_prefix

  bedrock_inference_profile_arn = local.bedrock_inference_profile_arn
  bedrock_foundation_model_arns = local.bedrock_foundation_model_arns

  dynamodb_table_arn = module.dynamodb.table_arn
  dynamodb_gsi_arns  = [module.dynamodb.gsi_arn]

  cors_allow_origins = [module.static_site.distribution_url]

  environment_variables = {
    APP_ENVIRONMENT           = var.environment
    LOG_LEVEL                 = "INFO"
    SSM_PATH_PREFIX           = local.ssm_prefix
    BEDROCK_MODEL_ID          = local.bedrock_inference_profile_arn
    AURORA_CLUSTER_IDENTIFIER = module.aurora.cluster_identifier
    AURORA_CLUSTER_ENDPOINT   = module.aurora.cluster_endpoint
    AURORA_SECRET_ARN         = module.aurora.master_user_secret_arn
    AURORA_DATABASE_NAME      = module.aurora.database_name
    AURORA_PORT               = tostring(module.aurora.port)
    DYNAMODB_TABLE_NAME       = module.dynamodb.table_name
  }

  # Force lambda_api to wait for SSM parameters so a fresh apply can't race
  # with a Lambda cold start that reads from SSM.
  depends_on = [
    aws_ssm_parameter.bedrock_model_id,
    aws_ssm_parameter.aurora_cluster_identifier,
    aws_ssm_parameter.aurora_cluster_endpoint,
    aws_ssm_parameter.aurora_secret_arn,
    aws_ssm_parameter.dynamodb_table_name,
  ]
}
