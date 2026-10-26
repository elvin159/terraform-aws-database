output "address" {
  description = "Postgres hostname for the app."
  value       = module.database.address
}

output "port" {
  description = "Postgres port."
  value       = module.database.port
}

output "database_name" {
  description = "App database name."
  value       = module.database.database_name
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret with the username and password. Add to terraform-aws-identity external_secrets.secrets_manager_arns."
  value       = module.database.master_user_secret_arn
}

output "kms_key_arn" {
  description = "KMS key for the secret. Add to terraform-aws-identity external_secrets.kms_key_arns."
  value       = module.database.kms_key_arn
}
