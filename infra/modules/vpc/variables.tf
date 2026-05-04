variable "name_prefix" {
  type        = string
  description = "Prefix used for the Name tag on every resource (typically project-environment)."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC. /16 recommended to leave room for cidrsubnet split."
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "availability_zones" {
  type        = list(string)
  description = "AZs to spread subnets across. Length determines subnet count."

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 availability zones are required."
  }
}

variable "single_nat_gateway" {
  type        = bool
  description = "If true, one NAT in the first public subnet shared across private subnets. v1 demo cost-saver; v1.5 should run one NAT per AZ for HA."
  default     = true
}
