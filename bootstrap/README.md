# bootstrap (one-time)

This folder bootstraps the shared infrastructure needed for Option A:

- S3 bucket for Terraform remote state
- DynamoDB table for Terraform state locking
- GitHub Actions OIDC provider + IAM role/policy so workflows can run Terraform without long-lived AWS keys

After applying this stack, follow the root `README.md` to configure the backend and GitHub Actions secrets/vars.

