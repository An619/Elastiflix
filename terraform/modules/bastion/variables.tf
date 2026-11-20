variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "bastion_instance_type" {
  type    = string
  default = "t4g.nano"
}
