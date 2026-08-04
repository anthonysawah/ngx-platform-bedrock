locals {
  az_count = length(var.availability_zones)

  # /16 → /20 = 4 new bits; 16 possible /20 subnets per /16.
  # Reserve 0..7 for public, 8..15 for private. Plenty of room to grow.
  public_subnet_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  # Public subnets exist only to host a NAT gateway. With egress disabled
  # there is nothing to put in them, so they aren't created at all.
  public_subnet_count = var.enable_internet_egress ? local.az_count : 0
  nat_count           = var.enable_internet_egress ? (var.single_nat_gateway ? 1 : local.az_count) : 0
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.name_prefix
  }
}

# ---------------------------------------------------------------------------
# Internet egress — disabled by default (ADR-013).
#
# The NAT gateway and its Elastic IP were $36/mo of a measured ~$82/mo
# bill, billed hourly whether or not a single byte flowed. They existed so the in-VPC
# Lambda could reach Bedrock, SSM, and Secrets Manager.
#
# After the API/executor split, nothing in this VPC needs the internet:
#   * the executor Lambda authenticates to Aurora with a locally-signed IAM
#     token (no Secrets Manager call) and reaches DynamoDB over the free
#     gateway endpoint below
#   * everything that does need public AWS APIs runs outside the VPC
#
# Flip enable_internet_egress back to true to restore NAT + IGW + public
# subnets in one apply if a future workload needs egress again.
# ---------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  count = var.enable_internet_egress ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  count = local.public_subnet_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.name_prefix}-private-${var.availability_zones[count.index]}"
    Tier = "private"
  }
}

resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.name_prefix}-nat-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  count = var.enable_internet_egress ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-public-rt"
    Tier = "public"
  }
}

resource "aws_route" "public_default" {
  count = var.enable_internet_egress ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count = local.public_subnet_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# Private route tables always exist — they carry the gateway-endpoint routes
# even when there is no default route out.
resource "aws_route_table" "private" {
  count = var.single_nat_gateway ? 1 : local.az_count

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-private-rt-${count.index}"
    Tier = "private"
  }
}

resource "aws_route" "private_default" {
  count = local.nat_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = var.single_nat_gateway ? aws_route_table.private[0].id : aws_route_table.private[count.index].id
}

# Gateway VPC endpoints — free, route-table attached, and the reason the
# executor Lambda can reach DynamoDB with no internet path at all (ADR-005).

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${var.name_prefix}-vpce-s3"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${var.name_prefix}-vpce-dynamodb"
  }
}
