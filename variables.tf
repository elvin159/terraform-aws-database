variable "name" {
  description = "DB instance identifier, usually <cluster>-<environment>-<app>, e.g. cluster1-prd-app. Also names the security group, subnet group, KMS alias and log groups."
  type        = string

  validation {
    # RDS identifiers allow 63 characters, no consecutive hyphens and no trailing hyphen.
    condition     = can(regex("^[a-z][a-z0-9-]{0,49}$", var.name)) && !strcontains(var.name, "--") && !endswith(var.name, "-")
    error_message = "name must be 1-50 characters: lowercase letters, digits and single hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "protection" {
  description = <<-EOT
    How hard the database is to destroy through Terraform:
      none     - dev. terraform destroy works and skips the final snapshot.
      standard - stg. RDS deletion protection is on and a final snapshot is taken on delete; set
                 protection = "none" and apply before destroying.
      strict   - prd. standard, plus any plan that would destroy or replace the instance or its KMS key
                 fails. Protection cannot be lowered through Terraform.
  EOT
  type        = string

  validation {
    condition     = contains(["none", "standard", "strict"], var.protection)
    error_message = "protection must be none, standard or strict."
  }
}

# Network

variable "vpc_id" {
  description = "VPC ID from terraform-aws-networking."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs in at least two AZs. The instance is never publicly accessible."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must contain at least two subnets in different AZs."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect on the Postgres port, e.g. the EKS cluster security group from terraform-aws-compute."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "CIDRs allowed to connect on the Postgres port, e.g. a VPN range. 0.0.0.0/0 is rejected."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.allowed_cidr_blocks : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "allowed_cidr_blocks must be valid IPv4 CIDRs and must not contain 0.0.0.0/0."
  }
}

# Engine and sizing

variable "engine_version" {
  description = "Postgres major version, e.g. 17. Minor versions are applied automatically in the maintenance window. Upgrade one major version at a time."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.engine_version))
    error_message = "engine_version must be a major version such as 17."
  }
}

variable "instance_class" {
  description = "DB instance class, e.g. db.t4g.medium or db.m7g.large."
  type        = string

  validation {
    condition     = startswith(var.instance_class, "db.")
    error_message = "instance_class must be an RDS instance class such as db.m7g.large."
  }
}

variable "multi_az" {
  description = "Run a standby in a second AZ with automatic failover. Turn off in dev only."
  type        = bool
  default     = true
}

variable "allocated_storage" {
  description = "Initial gp3 storage in GiB."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20 && var.allocated_storage <= 65536
    error_message = "allocated_storage must be between 20 and 65536 GiB."
  }
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB. Storage grows automatically up to this size and never shrinks."
  type        = number
  default     = 100

  validation {
    condition     = var.max_allocated_storage >= var.allocated_storage && var.max_allocated_storage <= 65536
    error_message = "max_allocated_storage must be at least allocated_storage and at most 65536 GiB."
  }
}

# Database

variable "database_name" {
  description = "Name of the database created on the instance for the app."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_name))
    error_message = "database_name must be 1-63 characters: lowercase letters, digits and underscores, starting with a letter."
  }
}

variable "master_username" {
  description = "Master user name. Its password is generated, stored and rotated by RDS in Secrets Manager; it never appears in Terraform."
  type        = string
  default     = "dbadmin"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,15}$", var.master_username)) && !contains(["postgres", "rdsadmin", "admin"], var.master_username)
    error_message = "master_username must be 1-16 characters: lowercase letters, digits and underscores, starting with a letter, and not a reserved name."
  }
}

variable "parameters" {
  description = <<-EOT
    Extra Postgres parameters, keyed by name. Merged over the module defaults (rds.force_ssl = 1).
      value        - Parameter value.
      apply_method - immediate (dynamic parameters) or pending-reboot (static parameters).
  EOT
  type = map(object({
    value        = string
    apply_method = optional(string, "immediate")
  }))
  default = {}

  validation {
    condition     = alltrue([for p in values(var.parameters) : contains(["immediate", "pending-reboot"], p.apply_method)])
    error_message = "parameters apply_method must be immediate or pending-reboot."
  }
}

# Operations

variable "backup_retention_days" {
  description = "Days to keep automated backups, for point-in-time recovery."
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 1 and 35."
  }
}

variable "backup_window" {
  description = "Daily backup window in UTC, hh24:mi-hh24:mi. Must not overlap maintenance_window."
  type        = string
  default     = "03:00-04:00"
}

variable "maintenance_window" {
  description = "Weekly maintenance window in UTC, ddd:hh24:mi-ddd:hh24:mi. Minor upgrades and pending changes apply here."
  type        = string
  default     = "sun:05:00-sun:06:00"
}

variable "apply_immediately" {
  description = "Apply changes such as instance class right away instead of in the next maintenance window. Changes can cause a restart."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Days to keep Postgres logs in CloudWatch Logs."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs supports, e.g. 30, 90 or 365."
  }
}

variable "kms_key_deletion_window_days" {
  description = "Waiting period before the encryption key is deleted after the database is destroyed."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "kms_key_deletion_window_days must be between 7 and 30."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
