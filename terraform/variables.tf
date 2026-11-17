
variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-2" # Ohio (Cost-effective)
}

variable "cluster_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "elastiflix"
}

variable "environment" {
  description = "Deployment environment (dev or production)"
  type        = string
  default     = "dev" # dev uses single NAT, production creates 3
}

variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion host"
  type        = string
  default     = "t4g.nano" # ARM-based, very cheap
}
