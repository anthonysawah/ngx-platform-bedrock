# DynamoDB table for runs.
#
# Item shape:
#   header row     — PK=run_id, SK="run",  has status/created_at + the full RunRecord
#   per-second row — PK=run_id, SK=ISO8601 timestamp, MetricSample fields
#
# GSI ("status-created_at"):
#   PK=status, SK=created_at — sparse GSI: only header rows have these keys,
#   so only header rows are indexed. Used for "last N runs of a given status".

locals {
  table_name = "${var.name_prefix}-${var.table_name_suffix}"
  gsi_name   = "status-created_at"
}

resource "aws_dynamodb_table" "this" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "run_id"
  range_key = "metric_ts"

  attribute {
    name = "run_id"
    type = "S"
  }

  attribute {
    name = "metric_ts"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  global_secondary_index {
    name            = local.gsi_name
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  server_side_encryption {
    enabled = true
  }

  deletion_protection_enabled = var.deletion_protection_enabled

  tags = {
    Name = local.table_name
  }
}
