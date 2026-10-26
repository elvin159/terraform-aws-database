output "identifier" {
  description = "DB instance identifier."
  value       = aws_db_instance.this.identifier
}

output "arn" {
  description = "DB instance ARN."
  value       = aws_db_instance.this.arn
}

output "address" {
  description = "Hostname to connect to. Follows the primary after a Multi-AZ failover."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Postgres port."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "Name of the app database."
  value       = aws_db_instance.this.db_name
}

output "master_username" {
  description = "Master user name."
  value       = aws_db_instance.this.username
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret with the master username and password, or null for a cross-region replica (it uses the source's secret). Pass to terraform-aws-identity external_secrets.secrets_manager_arns."
  value       = one(aws_db_instance.this.master_user_secret[*].secret_arn)
}

output "kms_key_arn" {
  description = "KMS key that encrypts storage and the master user secret. Pass to terraform-aws-identity external_secrets.kms_key_arns."
  value       = aws_kms_key.this.arn
}

output "security_group_id" {
  description = "Security group on the instance."
  value       = aws_security_group.this.id
}

output "read_replica_addresses" {
  description = "Hostnames of the in-region read replicas, keyed like var.read_replicas. Point read-only traffic here."
  value       = { for k, r in aws_db_instance.replica : k => r.address }
}

output "read_replica_identifiers" {
  description = "Identifiers of the in-region read replicas, keyed like var.read_replicas."
  value       = { for k, r in aws_db_instance.replica : k => r.identifier }
}

output "backup_replication_kms_key_arn" {
  description = "KMS key in the backup_replication region that encrypts the backup copies, or null."
  value       = one(aws_kms_key.backup_replication[*].arn)
}
