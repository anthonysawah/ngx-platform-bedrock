output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Primary CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered to match var.availability_zones."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered to match var.availability_zones."
  value       = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  description = "Route tables associated with the private subnets (used to attach gateway VPC endpoints later)."
  value       = aws_route_table.private[*].id
}

output "availability_zones" {
  description = "AZs the subnets were placed in."
  value       = var.availability_zones
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs."
  value       = aws_nat_gateway.this[*].id
}
