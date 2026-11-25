variable "aws_region" {
  type        = string
  description = "The target AWS deployment region"
  default     = "us-east-1"
}

variable "valkey_engine_version" {
  type        = string
  description = "The version of the Valkey cache engine"
  default     = "7.2"
}

variable "valkey_node_type" {
  type        = string
  description = "The instance hardware class for practice cost-reduction"
  default     = "cache.t4g.small"
}


