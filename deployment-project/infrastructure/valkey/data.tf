# Get the default VPC
data "aws_vpc" "default" {
  default = true
}

# Get the public subnets inside the default VPC
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }

  # Skip us-east-1e (use1-az3), it does not support cache.t4g nodes
  filter {
    name   = "availability-zone-id"
    values = ["use1-az1", "use1-az2", "use1-az4", "use1-az5", "use1-az6"]
  }
}