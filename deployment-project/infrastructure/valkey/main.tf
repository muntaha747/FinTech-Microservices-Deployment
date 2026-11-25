provider "aws" {
  region = var.aws_region
}

# Security group: allow Valkey port 6379 only from inside the VPC
resource "aws_security_group" "valkey_sg" {
  name   = "valkey-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 1. Create a Subnet Group from the public subnets found in data.tf
resource "aws_elasticache_subnet_group" "valkey_subnets" {
  name       = "valkey-cluster-practice-subnets"
  subnet_ids = data.aws_subnets.public.ids
}

# 2. Deploy the practice-friendly Valkey Cluster using variables
resource "aws_elasticache_replication_group" "valkey_practice" {
  replication_group_id = "fintech-valkey-dev"
  description          = "Cheap Valkey cluster for fintech practice"

  # Engine configuration driven by variables
  engine         = "valkey"
  engine_version = var.valkey_engine_version
  node_type      = var.valkey_node_type
  port           = 6379

  # High Availability setup optimized for cost (Non-sharded, 2 total nodes)
  automatic_failover_enabled = true
  multi_az_enabled           = false
  num_cache_clusters         = 2
  # prod usage # num_node_groups            = 3   # Number of Shards
  # prod usage # replicas_per_node_group    = 2   # Replicas per shard for high availability

  # Security & Networking driven by variables
  subnet_group_name          = aws_elasticache_subnet_group.valkey_subnets.name
  security_group_ids         = [aws_security_group.valkey_sg.id]
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  apply_immediately          = true
}
