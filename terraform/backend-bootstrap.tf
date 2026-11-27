# Remote-state durability for the S3 bucket that backend.tf points at.
#
# This root deliberately does NOT create the bucket: the bucket's name is a
# prerequisite for `terraform init`, so it must exist before this configuration
# can run, and creating it here would create a chicken-and-egg dependency. It
# documents and enforces the properties a state bucket needs.
#
# Usage (operator, reviewed change):
#   terraform import aws_s3_bucket.terraform_state elastiflix-terraform-state-an619
#   terraform import aws_dynamodb_table.terraform_locks terraform-locks
#   terraform plan   # must show only versioning/PITR/encryption/access changes
#
# These are same-region controls, not a regional failover design.
# The key is created here so encryption is customer-managed and reviewable; if
# key rotation or deletion policy must be centrally controlled, import an
# existing key instead of creating one.

variable "state_bucket_name" {
  description = "Existing S3 bucket that backend.tf configures as the Terraform state store."
  type        = string
  default     = "elastiflix-terraform-state-an619"
}

variable "state_lock_table_name" {
  description = "Existing DynamoDB table used for state locking."
  type        = string
  default     = "terraform-locks"
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = var.state_bucket_name

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = var.state_bucket_name

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = var.state_bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_kms_key" "terraform_state" {
  description             = "Encrypts the Terraform state bucket and lock table"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = var.cluster_name
    ManagedBy   = "terraform"
  }
}

# Explicit key policy: full control for the account principal (so Terraform can
# still manage the key) and nothing else. Without a policy statement the key is
# governed by the default policy, which this check flags as unauditable.
#
# It reuses the aws_caller_identity data source declared in eks.tf; declaring a
# second one with the same name is a duplicate-resource error at validate time.

resource "aws_kms_key_policy" "terraform_state" {
  key_id = aws_kms_key.terraform_state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowTerraformStateAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/${var.state_bucket_name}-state"
  target_key_id = aws_kms_key.terraform_state.key_id
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = var.state_lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.terraform_state.arn
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = var.cluster_name
    ManagedBy   = "terraform"
  }
}
