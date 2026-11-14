terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = var.name
      Purpose = "cdc-demo"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # With 3 AZs we get a properly durable Kafka setup (RF=3, min ISR=2).
  # With 2 AZs (the cheap default) we settle for RF=2, min ISR=1.
  replication_factor = var.az_count >= 3 ? 3 : 2
  min_insync         = var.az_count >= 3 ? 2 : 1

  topic_prefix = "cdc"
  cdc_topic    = "${local.topic_prefix}.public.transactions"
}
