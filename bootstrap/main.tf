data "aws_caller_identity" "current" {}

locals {
  derived_bucket = "iac-dev-box-tfstate-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  state_bucket   = var.tf_state_bucket_name != "" ? var.tf_state_bucket_name : local.derived_bucket

  derived_table = "iac-dev-box-tf-locks-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  lock_table    = var.tf_lock_table_name != "" ? var.tf_lock_table_name : local.derived_table

  state_key = "${var.tf_state_key_prefix}/${var.aws_region}/terraform.tfstate"
}

# ---------------------------------------------------------------------------
# Terraform backend: S3 bucket + DynamoDB lock table
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "tf_state" {
  bucket = local.state_bucket
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = local.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC → IAM role for Terraform
# ---------------------------------------------------------------------------
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  count = var.github_actions_oidc_provider_arn != "" ? 0 : 1

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

locals {
  gha_sub               = "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${var.github_branch}"
  gha_oidc_provider_arn = var.github_actions_oidc_provider_arn != "" ? var.github_actions_oidc_provider_arn : aws_iam_openid_connect_provider.github_actions[0].arn
}

resource "aws_iam_role" "gha_terraform" {
  name_prefix = "iac-dev-box-gha-terraform-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.gha_oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = local.gha_sub
          }
        }
      }
    ]
  })
}

# Broad-but-bounded policy: enough for this repo's Terraform to manage the dev box
resource "aws_iam_role_policy" "gha_terraform" {
  role = aws_iam_role.gha_terraform.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Terraform backend access
      {
        Sid    = "TerraformStateBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.tf_state.arn
      },
      {
        Sid    = "TerraformStateObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.tf_state.arn}/*"
      },
      {
        Sid    = "TerraformLockTable"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.tf_lock.arn
      },
      # Core infra managed by root stack (dev box)
      {
        Sid    = "Ec2VpcEbsSpotEip"
        Effect = "Allow"
        Action = [
          "ec2:*",
          "iam:*",
          "pricing:GetProducts",
          "secretsmanager:*",
          "ssm:GetParameter",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })
}

