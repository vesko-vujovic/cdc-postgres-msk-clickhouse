variable "name" {
  description = "Prefix for every resource name."
  type        = string
  default     = "cdc-demo"
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-central-1"
}

variable "az_count" {
  description = "Number of AZs (and MSK brokers). 2 is cheapest, 3 is what you want in production."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

# ---------- PostgreSQL ----------

variable "postgres_version" {
  description = "RDS for PostgreSQL major version."
  type        = string
  default     = "17"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "rds_storage_gb" {
  description = "Kept small on purpose so WAL growth from a stalled slot is easy to see in FreeStorageSpace."
  type        = number
  default     = 20
}

variable "rds_multi_az" {
  type    = bool
  default = false
}

variable "max_slot_wal_keep_size_mb" {
  description = <<-EOT
    Guardrail for a stalled replication slot. -1 means unlimited (PostgreSQL default):
    the slot keeps WAL until the disk is full. A positive value caps retained WAL, but when
    the cap is hit the slot is invalidated and Debezium needs a fresh snapshot.
  EOT
  type        = number
  default     = -1
}

# ---------- Kafka ----------

variable "kafka_version" {
  type    = string
  default = "3.8.x"
}

variable "msk_instance_type" {
  type    = string
  default = "kafka.t3.small"
}

variable "debezium_version" {
  description = "Debezium PostgreSQL connector version. 3.x needs Java 17, which MSK Connect 3.7.x provides."
  type        = string
  default     = "3.6.2.Final"
}

variable "create_connector" {
  description = "Create the Debezium connector. Leave false on the first apply, run `make init`, then set to true. Setting it back to false deletes the connector but NOT the replication slot (that is the failure demo)."
  type        = bool
  default     = false
}

variable "connector_mcu" {
  description = "MSK Connect capacity units per worker (1, 2, 4 or 8)."
  type        = number
  default     = 1
}

# ---------- ClickHouse box ----------

variable "box_instance_type" {
  description = "EC2 instance that runs ClickHouse and doubles as the psql client."
  type        = string
  default     = "t3.large"
}

# ---------- Alarms ----------

variable "slot_lag_alarm_bytes" {
  description = "Alarm when the oldest replication slot holds more WAL than this."
  type        = number
  default     = 268435456 # 256 MiB, low on purpose so the demo trips it
}

variable "alarm_email" {
  description = "Optional email for alarm notifications. Leave empty to skip SNS."
  type        = string
  default     = ""
}
