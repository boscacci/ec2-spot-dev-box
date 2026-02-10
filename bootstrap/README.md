# bootstrap (one-time)

This folder bootstraps the shared infrastructure needed for Option A:

- S3 bucket for Terraform remote state
- DynamoDB table for Terraform state locking
- GitHub Actions OIDC provider + IAM role/policy so workflows can run Terraform without long-lived AWS keys

After applying this stack, follow the root `README.md` to configure the backend and GitHub Actions secrets/vars.

## If you see: "Provider with url https://token.actions.githubusercontent.com already exists"

Your AWS account already has the GitHub Actions OIDC provider (e.g. from another repo or a previous run). Reuse it instead of creating a new one:

```bash
# Get your account ID and build the ARN (replace ACCOUNT_ID if needed)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
terraform apply -var="github_actions_oidc_provider_arn=arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
```

Or with a fixed ARN for account YOUR_ACCOUNT_ID:

```bash
terraform apply -var='github_actions_oidc_provider_arn=arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com'
```

Then re-run `terraform output` and add those values to GitHub (Settings → Secrets and variables → Actions) as described in the root README.

