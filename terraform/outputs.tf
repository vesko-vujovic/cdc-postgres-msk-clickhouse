output "region" {
  value = var.region
}

output "box_instance_id" {
  description = "Connect with: aws ssm start-session --target <id>"
  value       = aws_instance.box.id
}

output "rds_endpoint" {
  value = aws_db_instance.pg.address
}

output "msk_bootstrap_brokers" {
  value = aws_msk_cluster.this.bootstrap_brokers
}

output "cdc_topic" {
  value = local.cdc_topic
}

output "connector_log_group" {
  value = aws_cloudwatch_log_group.connect.name
}

output "connector_arn" {
  value = try(aws_mskconnect_connector.debezium[0].arn, null)
}
