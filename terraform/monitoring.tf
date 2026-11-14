# The two RDS metrics that tell you a slot is hurting the database.
# OldestReplicationSlotLag: bytes of WAL the slowest slot still needs.
# FreeStorageSpace: what you lose while that number grows.

resource "aws_sns_topic" "alarms" {
  count = var.alarm_email == "" ? 0 : 1
  name  = "${var.name}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  alarm_actions = var.alarm_email == "" ? [] : [aws_sns_topic.alarms[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "slot_lag" {
  alarm_name          = "${var.name}-replication-slot-lag"
  alarm_description   = "A replication slot is holding WAL. Is the connector running?"
  namespace           = "AWS/RDS"
  metric_name         = "OldestReplicationSlotLag"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.pg.identifier }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.slot_lag_alarm_bytes
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "free_storage" {
  alarm_name          = "${var.name}-free-storage-low"
  alarm_description   = "RDS is running out of disk. Check replication slots first."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.pg.identifier }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.rds_storage_gb * 1073741824 * 0.25 # 25% left
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
