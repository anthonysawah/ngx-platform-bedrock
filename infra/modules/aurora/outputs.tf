output "cluster_arn" {
  description = "ARN of the Aurora cluster."
  value       = aws_rds_cluster.this.arn
}

output "cluster_identifier" {
  description = "Aurora cluster identifier (used by describe_db_clusters for ACU sampling)."
  value       = aws_rds_cluster.this.cluster_identifier
}

output "cluster_resource_id" {
  description = "Cluster resource ID (used to scope IAM auth in v1.5)."
  value       = aws_rds_cluster.this.cluster_resource_id
}

output "cluster_endpoint" {
  description = "Writer endpoint (DNS) the application connects to."
  value       = aws_rds_cluster.this.endpoint
}

output "cluster_reader_endpoint" {
  description = "Reader endpoint (currently same as writer; populated for v1.5)."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "port" {
  description = "Database port."
  value       = aws_rds_cluster.this.port
}

output "database_name" {
  description = "Initial database created in the cluster."
  value       = aws_rds_cluster.this.database_name
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding master credentials JSON."
  value       = aws_secretsmanager_secret.master.arn
}

output "security_group_id" {
  description = "Aurora cluster security group ID. Lambda module adds ingress rule from lambda SG → 5432."
  value       = aws_security_group.cluster.id
}
