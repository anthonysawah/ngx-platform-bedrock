variable "name_prefix" {
  type        = string
  description = "Prefix used for the table name and tags."
}

variable "table_name_suffix" {
  type        = string
  description = "Appended to name_prefix to form the table name."
  default     = "runs"
}

variable "point_in_time_recovery" {
  type        = bool
  description = "Enable PITR (last 35 days)."
  default     = true
}

variable "deletion_protection_enabled" {
  type        = bool
  description = "Block accidental table deletes. v1 demo leaves this false to allow terraform destroy; flip to true for any real environment."
  default     = false
}
