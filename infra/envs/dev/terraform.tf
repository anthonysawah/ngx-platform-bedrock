# AWS provider pinned to exact version (head of 5.x at time of bootstrap).
# Bump deliberately; record changes in DECISIONS.md.
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.100.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.3"
    }
  }
}
