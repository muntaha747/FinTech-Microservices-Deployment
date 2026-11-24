variable "aws_region" {
  default = "us-east-1"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    kafka = {
      source  = "Mongey/kafka"
      version = ">= 0.5.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "kafka" {
  # Splits the MSK bootstrap string into a list of broker addresses
  bootstrap_servers = split(",", data.aws_msk_bootstrap_brokers.kafka_endpoints.bootstrap_brokers_sasl_iam)

  tls_enabled     = true
  sasl_mechanism  = "aws-iam"
  sasl_aws_region = var.aws_region
}
