output "state_bucket_name" {
  description = "S3 bucket to place in the S3 backend configuration."
  value       = aws_s3_bucket.terraform_state.bucket
}

output "state_lock_table_name" {
  description = "DynamoDB table to place in the S3 backend configuration."
  value       = aws_dynamodb_table.terraform_locks.name
}

output "state_kms_key_arn" {
  description = "Customer-managed KMS key ARN for encrypting the S3 backend state."
  value       = aws_kms_key.terraform_state.arn
}
