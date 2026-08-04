output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Primary CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs. Empty when enable_internet_egress is false (the default) -- public subnets exist only to host a NAT gateway."
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
  description = "NAT gateway IDs. Empty when enable_internet_egress is false (the default)."
  value       = aws_nat_gateway.this[*].id
}

output "gateway_endpoint_prefix_list_ids" {
  description = <<-EOT
    Managed prefix list IDs for the S3 and DynamoDB gateway endpoints.

    Gateway endpoints are route-table based, but traffic to them still leaves
    an instance/ENI through its security group -- so an SG with no matching
    egress rule blocks them. Consumers need an egress rule on 443 to these
    prefix lists. Using the prefix list rather than 0.0.0.0/0 keeps the
    "no internet path" property intact.
  EOT
  value = [
    aws_vpc_endpoint.s3.prefix_list_id,
    aws_vpc_endpoint.dynamodb.prefix_list_id,
  ]
}
