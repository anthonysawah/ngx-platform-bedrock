output "vpc_id" {
  description = "ID of the VPC for this environment."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "Primary CIDR block of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs (Lambda + Aurora live here)."
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs (NAT lives here; nothing else by design)."
  value       = module.vpc.public_subnet_ids
}

output "availability_zones" {
  description = "AZs the subnets are placed in."
  value       = module.vpc.availability_zones
}
