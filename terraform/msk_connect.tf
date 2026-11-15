# ---------- Custom plugin: Debezium PostgreSQL connector ----------
# MSK Connect only accepts ZIP or JAR plugins, so `make plugin` downloads the
# Debezium .tar.gz from Maven Central and repackages it as a ZIP in ../build.

resource "aws_s3_bucket" "plugins" {
  bucket_prefix = "${var.name}-plugins-"
  force_destroy = true
}

locals {
  plugin_file = "${path.module}/../build/debezium-connector-postgres-${var.debezium_version}.zip"
}

resource "aws_s3_object" "debezium" {
  bucket = aws_s3_bucket.plugins.id
  key    = "debezium-connector-postgres-${var.debezium_version}.zip"
  source = local.plugin_file
  etag   = filemd5(local.plugin_file)
}

resource "aws_mskconnect_custom_plugin" "debezium" {
  name         = "${var.name}-debezium-pg-${replace(lower(var.debezium_version), ".", "-")}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.plugins.arn
      file_key   = aws_s3_object.debezium.key
    }
  }
}

# ---------- Worker configuration ----------
# The fixed offset topic is the important line. By default every MSK Connect
# connector gets its own offset topic tied to its ID, so deleting and
# recreating the connector forgets where it was and Debezium snapshots again.
# With a fixed topic, a recreated connector picks up from its last offset.

resource "aws_mskconnect_worker_configuration" "this" {
  name = "${var.name}-worker"

  properties_file_content = <<-EOT
    key.converter=org.apache.kafka.connect.json.JsonConverter
    key.converter.schemas.enable=false
    value.converter=org.apache.kafka.connect.json.JsonConverter
    value.converter.schemas.enable=false
    offset.storage.topic=__cdc_demo_connect_offsets
  EOT
}

# ---------- IAM + logs ----------

resource "aws_iam_role" "connector" {
  name = "${var.name}-msk-connect"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "kafkaconnect.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudwatch_log_group" "connect" {
  name              = "/msk-connect/${var.name}"
  retention_in_days = 7
}

# ---------- The connector ----------

locals {
  connector_config = {
    "connector.class" = "io.debezium.connector.postgresql.PostgresConnector"
    # A PostgreSQL slot has exactly one reader, so this is always 1.
    "tasks.max" = "1"

    "database.hostname" = aws_db_instance.pg.address
    "database.port"     = tostring(aws_db_instance.pg.port)
    "database.user"     = "debezium"
    "database.password" = random_password.debezium.result # demo only, use a config provider in production
    "database.dbname"   = aws_db_instance.pg.db_name
    "database.sslmode"  = "require"

    "topic.prefix" = local.topic_prefix

    # Replication: built-in pgoutput plugin, a named slot, and a publication
    # we create ourselves in sql/postgres_init.sql (least privilege).
    "plugin.name"                 = "pgoutput"
    "slot.name"                   = "debezium_slot"
    "publication.name"            = "dbz_publication"
    "publication.autocreate.mode" = "disabled"
    "table.include.list"          = "public.transactions"
    "snapshot.mode"               = "initial"

    # NUMERIC would otherwise arrive as base64 bytes.
    "decimal.handling.mode" = "string"

    # Heartbeat: keeps the slot moving even when captured tables are quiet.
    # On RDS this matters because RDS writes to its own internal tables, which
    # produces WAL the slot has to keep until Debezium confirms a newer LSN.
    "heartbeat.interval.ms"  = "10000"
    "heartbeat.action.query" = "UPDATE public.debezium_heartbeat SET ts = now() WHERE id = 1"

    # Flatten the before/after envelope into a plain row for ClickHouse.
    # Deletes become a row with __deleted=true instead of a tombstone.
    "transforms"                                       = "unwrap"
    "transforms.unwrap.type"                           = "io.debezium.transforms.ExtractNewRecordState"
    "transforms.unwrap.delete.tombstone.handling.mode" = "rewrite"
    "transforms.unwrap.add.fields"                     = "op,lsn,source.ts_ms"
    "tombstones.on.delete"                             = "false"

    "topic.creation.default.replication.factor" = tostring(local.replication_factor)
    "topic.creation.default.partitions"         = "3"
  }
}

resource "aws_mskconnect_connector" "debezium" {
  count = var.create_connector ? 1 : 0

  name                 = "${var.name}-debezium-pg"
  kafkaconnect_version = "3.7.x" # Java 17 runtime, required by Debezium 3.x

  capacity {
    provisioned_capacity {
      mcu_count    = var.connector_mcu
      worker_count = 1
    }
  }

  connector_configuration = local.connector_config

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = aws_msk_cluster.this.bootstrap_brokers

      vpc {
        security_groups = [aws_security_group.internal.id]
        subnets         = aws_subnet.private[*].id
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "NONE"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "PLAINTEXT"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.debezium.arn
      revision = aws_mskconnect_custom_plugin.debezium.latest_revision
    }
  }

  worker_configuration {
    arn      = aws_mskconnect_worker_configuration.this.arn
    revision = aws_mskconnect_worker_configuration.this.latest_revision
  }

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.connect.name
      }
    }
  }

  service_execution_role_arn = aws_iam_role.connector.arn
}

# The service execution role needs real permissions, not just a trust policy.
# MSK Connect validates log delivery when the connector is created and returns
# AccessDeniedException if this role cannot write to the log group, and the
# worker needs to fetch the plugin ZIP from S3 when it starts.
resource "aws_iam_role_policy" "connector" {
  name = "${var.name}-msk-connect"
  role = aws_iam_role.connector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents",
        ]
        Resource = [
          aws_cloudwatch_log_group.connect.arn,
          "${aws_cloudwatch_log_group.connect.arn}:*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.plugins.arn}/*"
      },
    ]
  })
}
