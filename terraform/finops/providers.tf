provider "aws" {
  # AWS Budgets is a global service signed in us-east-1. This is independent of
  # the region where the EKS demo stack runs.
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Purpose   = "Demo cost visibility"
    }
  }
}
