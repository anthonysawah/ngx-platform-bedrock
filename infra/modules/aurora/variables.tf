variable "name_prefix" {
  type        = string
  description = "Prefix used for the Name tag and identifier on every resource."
}

variable "vpc_id" {
  type        = string
  description = "VPC the Aurora SG lives in."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs the DB subnet group spans. At least 2 subnets in 2 AZs are required by RDS."

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Aurora requires at least 2 subnets across 2 AZs."
  }
}

variable "engine_version" {
  type        = string
  description = "Aurora Postgres engine version. Pin to a current 15.x patch."
  default     = "15.17"
}

variable "min_capacity" {
  type        = number
  description = <<-EOT
    Aurora Serverless v2 minimum ACUs.

    0 enables scale-to-zero: the cluster auto-pauses when idle and bills
    nothing for compute until the next connection. That removed the idle
    floor of ~$43.20/mo (measured steady state: 12 ACU-hours/day at
    $0.12/ACU-hr — a flat 0.50 average, i.e. the floor and nothing above it).

    Requires Aurora PostgreSQL 13.15+/14.12+/15.7+/16.3+. Costs a ~15s cold
    start on the first query after a pause.

    0.5 keeps the cluster permanently warm at ~$43/mo.
  EOT
  default     = 0

  validation {
    condition     = var.min_capacity == 0 || var.min_capacity >= 0.5
    error_message = "min_capacity must be 0 (scale-to-zero) or >= 0.5. Values between 0 and 0.5 are rejected by Aurora."
  }
}

variable "max_capacity" {
  type        = number
  description = "Aurora Serverless v2 maximum ACUs. v1 demo uses 4 to bound cost; raise for real load."
  default     = 4

  validation {
    condition     = var.max_capacity <= 16
    error_message = "max_capacity is capped at 16 ACUs in this module to prevent runaway demo cost. Raise the bound if you need more."
  }
}

variable "database_name" {
  type        = string
  description = "Initial database created in the cluster."
  default     = "workload"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_name))
    error_message = "database_name must start with a lowercase letter and contain only lowercase, digits, underscore."
  }
}

variable "master_username" {
  type        = string
  description = "Master DB username. Stored in the Secrets Manager secret alongside the generated password."
  default     = "workload_admin"
}

variable "backup_retention_days" {
  type        = number
  description = "Days of automated backups. v1 demo uses 1."
  default     = 1
}
