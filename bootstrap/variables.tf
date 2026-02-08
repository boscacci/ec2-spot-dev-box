variable "aws_region" {
  description = "AWS region to create the backend + IAM resources in."
  type        = string
  default     = "us-west-2"
}

variable "github_owner" {
  description = "GitHub org/user that owns the repo."
  type        = string
  default     = "boscacci"
}

variable "github_repo" {
  description = "GitHub repo name (without owner)."
  type        = string
  default     = "iac-dev-box"
}

variable "github_branch" {
  description = "Branch allowed to assume the Terraform role via OIDC."
  type        = string
  default     = "main"
}

variable "github_environment" {
  description = "Optional GitHub Environment name to allow in the OIDC subject (sub) claim (e.g. 'dev-box'). If set, environment-based workflow runs can assume the role."
  type        = string
  default     = "dev-box"
}

variable "github_workflow_file" {
  description = "Optional workflow file name to pin via the OIDC job_workflow_ref claim (e.g. 'dev-box.yml'). Empty disables job_workflow_ref pinning."
  type        = string
  default     = "dev-box.yml"
}

variable "github_actions_oidc_provider_arn" {
  description = "Optional: ARN of an existing IAM OIDC provider for GitHub Actions (token.actions.githubusercontent.com). If set, this stack will reuse it instead of creating a new provider."
  type        = string
  default     = ""
}

variable "tf_state_bucket_name" {
  description = "Optional explicit S3 bucket name for Terraform state. If empty, a name is derived from account+region."
  type        = string
  default     = ""
}

variable "tf_lock_table_name" {
  description = "Optional explicit DynamoDB table name for Terraform locking. If empty, a name is derived from account+region."
  type        = string
  default     = ""
}

variable "tf_state_key_prefix" {
  description = "Key prefix inside the state bucket (e.g. 'iac-dev-box/us-west-2')."
  type        = string
  default     = "iac-dev-box"
}

