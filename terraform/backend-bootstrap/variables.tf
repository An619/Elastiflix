variable "aws_region" {
  description = "AWS region for the Terraform state bucket and lock table."
  type        = string
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string

  validation {
    condition     = length(var.state_bucket_name) >= 3 && length(var.state_bucket_name) <= 51
    error_message = "state_bucket_name must be 3 to 51 characters long so the derived access-log bucket remains within S3's 63-character limit."
  }
}

variable "state_lock_table_name" {
  description = "DynamoDB table name for Terraform state locking."
  type        = string
}

variable "access_log_bucket_name" {
  description = "Name of an existing, approved S3 access-log bucket in the same AWS account and region, already configured to accept server access logs from the state bucket."
  type        = string

  validation {
    condition     = length(trimspace(var.access_log_bucket_name)) > 0 && var.access_log_bucket_name != var.state_bucket_name
    error_message = "access_log_bucket_name must name a separate, non-empty S3 bucket."
  }
}
