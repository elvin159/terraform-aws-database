locals {
  port        = 5432
  log_exports = ["postgresql", "upgrade"]

  # Encrypted connections only. Applies to every client, including the master user.
  default_parameters = {
    "rds.force_ssl" = { value = "1", apply_method = "immediate" }
  }
  parameters = merge(local.default_parameters, var.parameters)
}

# One key for storage, snapshots, Performance Insights and the master user secret.

resource "aws_kms_key" "this" {
  description             = "RDS encryption for ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_key_deletion_window_days

  tags = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/rds/${var.name}"
  target_key_id = aws_kms_key.this.key_id
}

# Network

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids

  tags = var.tags
}

# Inbound on the Postgres port only from the listed sources. No egress rules: RDS needs none.
resource "aws_security_group" "this" {
  name        = "${var.name}-rds"
  description = "Postgres access to ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-rds" })
}

resource "aws_vpc_security_group_ingress_rule" "security_groups" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "Postgres from ${each.value}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = local.port
  to_port                      = local.port

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "cidrs" {
  for_each = toset(var.allowed_cidr_blocks)

  security_group_id = aws_security_group.this.id
  description       = "Postgres from ${each.value}"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = local.port
  to_port           = local.port

  tags = var.tags
}

# Parameters. The family changes on a major upgrade, so a new group is created before the old one
# is removed.

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-"
  family      = "postgres${var.engine_version}"
  description = "Postgres ${var.engine_version} parameters for ${var.name}"

  dynamic "parameter" {
    for_each = local.parameters

    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# Created before the instance so RDS doesn't create them without a retention period.
resource "aws_cloudwatch_log_group" "this" {
  for_each = toset(local.log_exports)

  name              = "/aws/rds/instance/${var.name}/${each.key}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# Instance

resource "aws_db_instance" "this" {
  identifier = var.name

  engine                      = "postgres"
  engine_version              = var.engine_version
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = true
  instance_class              = var.instance_class
  parameter_group_name        = aws_db_parameter_group.this.name

  db_name  = var.database_name
  username = var.master_username
  port     = local.port

  # RDS generates the password, stores it in Secrets Manager and rotates it every 7 days.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.this.arn

  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.this.arn

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false

  backup_retention_period  = var.backup_retention_days
  backup_window            = var.backup_window
  maintenance_window       = var.maintenance_window
  copy_tags_to_snapshot    = true
  delete_automated_backups = var.protection == "none"
  apply_immediately        = var.apply_immediately

  deletion_protection       = var.protection != "none"
  skip_final_snapshot       = var.protection == "none"
  final_snapshot_identifier = var.protection == "none" ? null : "${var.name}-final"

  enabled_cloudwatch_logs_exports       = local.log_exports
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.this.arn
  performance_insights_retention_period = 7

  tags = var.tags

  depends_on = [aws_cloudwatch_log_group.this]
}
