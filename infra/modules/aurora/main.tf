# Aurora Serverless v2 (Postgres). Cluster + single writer instance.
# - SG is created here with NO ingress rules. The lambda_api module declares
#   the cross-SG ingress rule at composition time (consumes this module's
#   security_group_id output, no cycle).
# - Master credentials are managed by AWS via manage_master_user_password.
#   The password never enters Terraform state. AWS auto-creates a Secrets
#   Manager secret; ARN is exposed via aws_rds_cluster.master_user_secret.
#   See DECISIONS.md ADR-007.
# - skip_final_snapshot + deletion_protection=false are v1 demo conveniences;
#   real environments must invert both.

resource "aws_db_subnet_group" "this" {
  name        = "${var.name_prefix}-aurora"
  description = "Aurora subnet group for ${var.name_prefix}"
  subnet_ids  = var.private_subnet_ids

  tags = {
    Name = "${var.name_prefix}-aurora-subnets"
  }
}

resource "aws_security_group" "cluster" {
  name        = "${var.name_prefix}-aurora"
  description = "Aurora Serverless v2 cluster SG. Ingress added by lambda_api module at composition time."
  vpc_id      = var.vpc_id

  egress {
    description = "Cluster nodes need no outbound; default-deny."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = []
    self        = true
  }

  tags = {
    Name = "${var.name_prefix}-aurora"
  }
}

resource "aws_rds_cluster_parameter_group" "this" {
  name        = "${var.name_prefix}-aurora-pg15"
  family      = "aurora-postgresql15"
  description = "Cluster parameters for ${var.name_prefix} Aurora Postgres 15"

  # Log slow queries (>= 1s) so we can see them in CloudWatch when the demo runs.
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  # Force SSL for connections; psycopg defaults to TLS so this is just enforcement.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = {
    Name = "${var.name_prefix}-aurora-pg15"
  }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier              = "${var.name_prefix}-aurora"
  engine                          = "aurora-postgresql"
  engine_mode                     = "provisioned"
  engine_version                  = var.engine_version
  database_name                   = var.database_name
  master_username                 = var.master_username
  manage_master_user_password     = true
  db_subnet_group_name            = aws_db_subnet_group.this.name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  vpc_security_group_ids          = [aws_security_group.cluster.id]
  port                            = 5432

  storage_encrypted       = true
  backup_retention_period = var.backup_retention_days
  preferred_backup_window = "03:00-04:00"

  # v1 demo: tear-down friendly. Production must flip both.
  skip_final_snapshot = true
  deletion_protection = false

  serverlessv2_scaling_configuration {
    min_capacity = var.min_capacity
    max_capacity = var.max_capacity
  }

  tags = {
    Name = "${var.name_prefix}-aurora"
  }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.name_prefix}-aurora-writer"
  cluster_identifier = aws_rds_cluster.this.id
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version
  instance_class     = "db.serverless"

  publicly_accessible = false
  apply_immediately   = true

  tags = {
    Name = "${var.name_prefix}-aurora-writer"
  }
}
