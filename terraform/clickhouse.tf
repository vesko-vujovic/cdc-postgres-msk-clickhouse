# A single EC2 instance in a private subnet that runs ClickHouse and acts as
# the psql client for the demo. You reach it with SSM, so no SSH keys and no
# public IP.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_iam_role" "box" {
  name = "${var.name}-box"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "box_ssm" {
  role       = aws_iam_role.box.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "box" {
  name = "${var.name}-box"
  role = aws_iam_role.box.name
}

locals {
  box_user_data = templatefile("${path.module}/templates/box_user_data.sh.tftpl", {
    pg_host         = aws_db_instance.pg.address
    pg_port         = aws_db_instance.pg.port
    pg_db           = aws_db_instance.pg.db_name
    pg_user         = aws_db_instance.pg.username
    pg_password     = random_password.master.result
    dbz_password    = random_password.debezium.result
    kafka_bootstrap = aws_msk_cluster.this.bootstrap_brokers
    kafka_topic     = local.cdc_topic

    cdc_sh              = file("${path.module}/../box/cdc.sh")
    postgres_init_sql   = file("${path.module}/../sql/postgres_init.sql")
    clickhouse_init_sql = file("${path.module}/../sql/clickhouse_init.sql")
    seed_sql            = file("${path.module}/../sql/seed.sql")
    churn_sql           = file("${path.module}/../sql/churn.sql")
    slot_sql            = file("${path.module}/../sql/slot_lag.sql")
  })
}

resource "aws_instance" "box" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.box_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.internal.id]
  iam_instance_profile   = aws_iam_instance_profile.box.name

  user_data                   = local.box_user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "${var.name}-clickhouse" }

  depends_on = [aws_nat_gateway.this, aws_route_table_association.private]
}
