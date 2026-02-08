output "tf_state_bucket" {
  description = "S3 bucket name for Terraform remote state."
  value       = aws_s3_bucket.tf_state.bucket
}

output "tf_lock_table" {
  description = "DynamoDB table name for Terraform state locking."
  value       = aws_dynamodb_table.tf_lock.name
}

output "tf_state_key" {
  description = "Suggested state key for the root stack."
  value       = local.state_key
}

output "gha_terraform_role_arn" {
  description = "IAM role ARN for GitHub Actions to assume via OIDC."
  value       = aws_iam_role.gha_terraform.arn
}

