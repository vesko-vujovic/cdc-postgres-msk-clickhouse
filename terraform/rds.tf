resource "random_password" "master" {
  length           = 24
  special          = true
  override_special = "-_=+"
}

resource "random_password" "debezium" {
  length           = 24
  special          = true
  override_special = "-_=+"
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_parameter_group" "pg" {
  name   = "${var.name}-pg${var.postgres_version}"
  family = "postgres${var.postgres_version}"

  # This is the one switch RDS needs for CDC. It sets wal_level=logical
  # under the hood. It is static, so it only applies after a reboot, but
  # because the group is attached at creation time the instance boots with it.
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Optional guardrail against a stalled slot filling the disk.
  dynamic "parameter" {
    for_each = var.max_slot_wal_keep_size_mb > 0 ? [1] : []
    content {
      name         = "max_slot_wal_keep_size"
      value        = tostring(var.max_slot_wal_keep_size_mb)
      apply_method = "immediate"
    }
  }
}

resource "aws_db_instance" "pg" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = var.rds_instance_class

  allocated_storage = var.rds_storage_gb
  storage_type      = "gp3"
  # No storage autoscaling on purpose. Autoscaling hides a stalled slot
  # until the bill arrives.

  db_name  = "appdb"
  username = "cdc_admin"
  password = random_password.master.result

  parameter_group_name   = aws_db_parameter_group.pg.name
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.internal.id]
  publicly_accessible    = false
  multi_az               = var.rds_multi_az

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}
