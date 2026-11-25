variable "aws_region" {
  description = "AWS region for the Terraform state bucket and lock table."
  type        = string
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string

  validation {
    condition     = length(var.state_bucket_name) >= 3 && length(var.state_bucket_name) <= 63
    error_message = "state_bucket_name must be 3 to 63 characters long."
  }
}

variable "state_lock_table_name" {
  description = "DynamoDB table name for Terraform state locking."
  type        = string
}
