resource "aws_msk_configuration" "this" {
  name           = "${var.name}-config"
  kafka_versions = [var.kafka_version]

  # MSK ships with auto topic creation off. Debezium also asks Kafka Connect
  # to create topics (topic.creation.* in the connector config), but turning
  # this on means the heartbeat topic and any new table topics just work.
  server_properties = <<-EOT
    auto.create.topics.enable=true
    default.replication.factor=${local.replication_factor}
    min.insync.replicas=${local.min_insync}
    num.partitions=3
    log.retention.hours=72
  EOT
}

resource "aws_msk_cluster" "this" {
  cluster_name           = var.name
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.az_count

  broker_node_group_info {
    instance_type   = var.msk_instance_type
    client_subnets  = aws_subnet.private[*].id
    security_groups = [aws_security_group.internal.id]

    storage_info {
      ebs_storage_info {
        volume_size = 20
      }
    }
  }

  # Demo shortcut: plaintext and no auth inside the VPC.
  # Production: IAM auth + TLS (MSK Connect and ClickHouse both support it).
  client_authentication {
    unauthenticated = true
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS_PLAINTEXT"
      in_cluster    = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }
}
