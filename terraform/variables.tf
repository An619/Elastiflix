variable "aws_region" {
  description = "AWS region to deploy resources; verify service availability and cost before use."
  type        = string
  default     = "us-east-2"
}

variable "cluster_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "elastiflix"
}

variable "environment" {
  description = "Deployment environment; dev uses a single NAT gateway, production one per AZ."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "production"], var.environment)
    error_message = "environment must be either dev or production."
  }
}

variable "cluster_version" {
  description = "EKS Kubernetes minor version. Kept as a variable so upgrades are a reviewed change rather than an implicit module default."
  type        = string
  default     = "1.30"

  validation {
    condition     = can(regex("^1\\.(2[89]|3[0-9])$", var.cluster_version))
    error_message = "cluster_version must be a supported 1.x EKS minor version (1.28 or newer)."
  }
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Explicit CIDRs allowed to reach the public EKS API endpoint. Empty (the default) disables public access entirely and requires the SSM bastion. Never use 0.0.0.0/0."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.cluster_endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "cluster_endpoint_public_access_cidrs must not contain 0.0.0.0/0; the control plane endpoint cannot be world-reachable."
  }
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs. The NetworkPolicies in kubernetes/*/network-policy.yaml allow ingress only from the public subnet CIDRs below, so keep both lists in sync."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (load balancer nodes). Mirrored in the frontend/backend ingress NetworkPolicies."
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}
