# Offline tests: plan only against a mocked AWS provider, so no credentials or network are needed.
# Run with: terraform init && terraform test

mock_provider "aws" {
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000" }
  }
}

variables {
  name           = "cluster1-dev-app"
  protection     = "none"
  vpc_id         = "vpc-0123456789abcdef0"
  subnet_ids     = ["subnet-aaaa", "subnet-bbbb", "subnet-cccc"]
  engine_version = "17"
  instance_class = "db.t4g.medium"
  database_name  = "app"
}

run "secure_defaults" {
  command = plan

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "The instance must never be publicly accessible."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted && aws_db_instance.this.storage_type == "gp3"
    error_message = "Storage must be encrypted gp3."
  }

  assert {
    condition     = aws_db_instance.this.manage_master_user_password == true && aws_db_instance.this.password == null
    error_message = "The master password must be managed by RDS in Secrets Manager, never set in Terraform."
  }

  assert {
    condition     = one([for p in aws_db_parameter_group.this.parameter : p.value if p.name == "rds.force_ssl"]) == "1"
    error_message = "SSL must be enforced."
  }

  assert {
    condition     = aws_db_parameter_group.this.family == "postgres17"
    error_message = "Parameter group family must follow engine_version."
  }

  assert {
    condition     = aws_db_instance.this.multi_az == true
    error_message = "Multi-AZ must be on by default."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.security_groups) == 0 && length(aws_vpc_security_group_ingress_rule.cidrs) == 0
    error_message = "No access should be granted unless configured."
  }

  assert {
    condition     = toset(aws_db_instance.this.enabled_cloudwatch_logs_exports) == toset(keys(aws_cloudwatch_log_group.this))
    error_message = "Every exported log must have a log group with a retention period."
  }
}

run "dev_has_no_protection" {
  command = plan

  assert {
    condition     = aws_db_instance.this.deletion_protection == false && aws_db_instance.this.skip_final_snapshot == true
    error_message = "protection = none must allow terraform destroy without a final snapshot."
  }

  assert {
    condition     = length(terraform_data.guard) == 0
    error_message = "protection = none must not create the guard."
  }
}

run "standard_protection" {
  command = plan

  variables {
    protection = "standard"
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection == true && aws_db_instance.this.skip_final_snapshot == false
    error_message = "protection = standard must turn on deletion protection and take a final snapshot."
  }

  assert {
    condition     = aws_db_instance.this.final_snapshot_identifier == "cluster1-dev-app-final"
    error_message = "Unexpected final snapshot identifier."
  }

  assert {
    condition     = length(terraform_data.guard) == 0
    error_message = "protection = standard must not create the guard."
  }
}

run "strict_protection" {
  command = plan

  variables {
    protection = "strict"
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection == true
    error_message = "protection = strict must turn on deletion protection."
  }

  assert {
    condition     = length(terraform_data.guard) == 1
    error_message = "protection = strict must create the guard."
  }
}

run "access_rules" {
  command = plan

  variables {
    allowed_security_group_ids = ["sg-0123456789abcdef0"]
    allowed_cidr_blocks        = ["10.255.0.0/16"]
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.security_groups["sg-0123456789abcdef0"].from_port == 5432 && aws_vpc_security_group_ingress_rule.security_groups["sg-0123456789abcdef0"].referenced_security_group_id == "sg-0123456789abcdef0"
    error_message = "Allowed security groups must reach Postgres on 5432."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.cidrs["10.255.0.0/16"].to_port == 5432
    error_message = "Allowed CIDRs must reach Postgres on 5432."
  }
}

run "extra_parameters" {
  command = plan

  variables {
    parameters = {
      log_min_duration_statement = { value = "1000" }
      shared_preload_libraries   = { value = "pg_stat_statements", apply_method = "pending-reboot" }
    }
  }

  assert {
    condition     = length(aws_db_parameter_group.this.parameter) == 3
    error_message = "Extra parameters must be merged with the defaults."
  }
}

run "rejects_open_cidr" {
  command = plan

  variables {
    allowed_cidr_blocks = ["0.0.0.0/0"]
  }

  expect_failures = [var.allowed_cidr_blocks]
}

run "rejects_minor_version" {
  command = plan

  variables {
    engine_version = "17.2"
  }

  expect_failures = [var.engine_version]
}

run "rejects_unknown_protection" {
  command = plan

  variables {
    protection = "off"
  }

  expect_failures = [var.protection]
}

run "rejects_storage_ceiling_below_initial" {
  command = plan

  variables {
    allocated_storage     = 100
    max_allocated_storage = 50
  }

  expect_failures = [var.max_allocated_storage]
}

run "rejects_single_subnet" {
  command = plan

  variables {
    subnet_ids = ["subnet-aaaa"]
  }

  expect_failures = [var.subnet_ids]
}

run "primary_has_no_replication_by_default" {
  command = plan

  assert {
    condition     = aws_db_instance.this.replicate_source_db == null && length(aws_db_instance.replica) == 0
    error_message = "No replicas should be created unless configured."
  }

  assert {
    condition     = length(aws_db_instance_automated_backups_replication.this) == 0 && length(aws_kms_key.backup_replication) == 0
    error_message = "Backups should not be copied to another region unless configured."
  }
}

run "in_region_read_replicas" {
  command = plan

  variables {
    read_replicas = {
      read1 = {}
      read2 = { instance_class = "db.t4g.small" }
    }
  }

  assert {
    condition     = aws_db_instance.replica["read1"].identifier == "cluster1-dev-app-read1" && aws_db_instance.replica["read1"].replicate_source_db == "cluster1-dev-app"
    error_message = "Read replicas must be named <name>-<key> and replicate the primary."
  }

  assert {
    condition     = aws_db_instance.replica["read1"].instance_class == "db.t4g.medium" && aws_db_instance.replica["read2"].instance_class == "db.t4g.small"
    error_message = "instance_class must default to the primary's class and be overridable."
  }

  assert {
    condition     = aws_db_instance.replica["read1"].publicly_accessible == false && aws_db_instance.replica["read1"].backup_retention_period == 0
    error_message = "Read replicas must be private and have no automated backups of their own."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.replica) == 4 && aws_cloudwatch_log_group.replica["read1/postgresql"].name == "/aws/rds/instance/cluster1-dev-app-read1/postgresql"
    error_message = "Every replica log export must have a log group with a retention period."
  }
}

run "cross_region_replica" {
  command = plan

  variables {
    name                = "cluster1-prd-usw1"
    protection          = "strict"
    database_name       = null
    replicate_source_db = "arn:aws:rds:us-east-1:111111111111:db:cluster1-prd-use1"
  }

  assert {
    condition     = aws_db_instance.this.replicate_source_db == "arn:aws:rds:us-east-1:111111111111:db:cluster1-prd-use1"
    error_message = "The instance must replicate the source."
  }

  assert {
    condition     = aws_db_instance.this.manage_master_user_password == null
    error_message = "A replica uses the source's master user, so it must not manage a secret of its own."
  }

  assert {
    condition     = aws_db_instance.this.backup_retention_period == 0 && aws_db_instance.this.skip_final_snapshot == true
    error_message = "A replica has no automated backups or final snapshot."
  }

  assert {
    condition     = aws_db_instance.this.storage_encrypted && aws_db_instance.this.publicly_accessible == false
    error_message = "A cross-region replica must be encrypted and private."
  }

  assert {
    condition     = aws_db_instance.this.deletion_protection == true && length(terraform_data.guard) == 1
    error_message = "Protection applies to replicas too."
  }
}

run "backup_replication" {
  command = plan

  variables {
    backup_replication = { region = "us-west-1", retention_days = 14 }
  }

  assert {
    condition     = aws_db_instance_automated_backups_replication.this[0].region == "us-west-1" && aws_db_instance_automated_backups_replication.this[0].retention_period == 14
    error_message = "Backups must be copied to the configured region for the configured days."
  }

  assert {
    condition     = aws_kms_key.backup_replication[0].region == "us-west-1" && aws_kms_key.backup_replication[0].enable_key_rotation
    error_message = "Backup copies must be encrypted with a rotating key in the destination region."
  }
}

run "rejects_primary_without_database_name" {
  command = plan

  variables {
    database_name = null
  }

  expect_failures = [var.database_name]
}

run "rejects_database_name_on_replica" {
  command = plan

  variables {
    replicate_source_db = "arn:aws:rds:us-east-1:111111111111:db:cluster1-prd-use1"
  }

  expect_failures = [var.database_name]
}

run "rejects_read_replicas_on_replica" {
  command = plan

  variables {
    database_name       = null
    replicate_source_db = "arn:aws:rds:us-east-1:111111111111:db:cluster1-prd-use1"
    read_replicas       = { read1 = {} }
  }

  expect_failures = [var.read_replicas]
}

run "rejects_backup_replication_on_replica" {
  command = plan

  variables {
    database_name       = null
    replicate_source_db = "arn:aws:rds:us-east-1:111111111111:db:cluster1-prd-use1"
    backup_replication  = { region = "us-west-2" }
  }

  expect_failures = [var.backup_replication]
}

run "rejects_bad_source_arn" {
  command = plan

  variables {
    database_name       = null
    replicate_source_db = "cluster1-prd-use1"
  }

  expect_failures = [var.replicate_source_db]
}
