
variable "aws_region" {
  description = "AWS region to deploy resources; verify availability and costs before use."
  type        = string
  default     = "us-east-2"
}

variable "cluster_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "elastiflix"
}

variable "environment" {
  description = "Deployment environment; dev uses one NAT gateway and production uses one per AZ."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "production"], var.environment)
    error_message = "environment must be either dev or production."
  }
}

variable "availability_zone_names" {
  description = "Exactly three available, account-specific AZ names for this VPC (for example, us-east-2a, us-east-2b, us-east-2c). Confirm mappings and availability in the target account and region before planning."
  type        = list(string)

  validation {
    condition     = length(var.availability_zone_names) == 3 && length(toset(var.availability_zone_names)) == 3
    error_message = "availability_zone_names must contain exactly three distinct AZ names."
  }
}

variable "cluster_version" {
  description = "EKS Kubernetes minor version; verify AWS, provider, and add-on support before setting."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.cluster_version))
    error_message = "cluster_version must be a Kubernetes major.minor version such as 1.30."
  }
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Optional IPv4 CIDRs allowed to reach the public EKS API endpoint. Empty keeps the API private-only."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.cluster_endpoint_public_access_cidrs :
      can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]), 0) >= 16
    ])
    error_message = "Public EKS API CIDRs must be valid IPv4 ranges no broader than /16; prefer a fixed administrator /32."
  }
}
