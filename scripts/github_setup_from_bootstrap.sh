#!/usr/bin/env bash
# Print exact GitHub Actions setup from bootstrap outputs.
# Run after: cd bootstrap && terraform init && terraform apply
# Then add the printed secret/variables in: Settings → Secrets and variables → Actions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BOOTSTRAP_DIR="$REPO_DIR/bootstrap"

if [ ! -d "$BOOTSTRAP_DIR" ]; then
  echo "Bootstrap dir not found: $BOOTSTRAP_DIR" >&2
  exit 1
fi

cd "$BOOTSTRAP_DIR"
if ! terraform output -json &>/dev/null; then
  echo "Bootstrap not applied or terraform not initialized. Run:" >&2
  echo "  cd bootstrap && terraform init && terraform apply" >&2
  exit 1
fi

ROLE_ARN=$(terraform output -raw gha_terraform_role_arn 2>/dev/null || true)
BUCKET=$(terraform output -raw tf_state_bucket 2>/dev/null || true)
KEY=$(terraform output -raw tf_state_key 2>/dev/null || true)
TABLE=$(terraform output -raw tf_lock_table 2>/dev/null || true)

if [ -z "$ROLE_ARN" ] || [ -z "$BUCKET" ]; then
  echo "Could not read bootstrap outputs. Run: cd bootstrap && terraform apply" >&2
  exit 1
fi

echo "=============================================="
echo "GitHub Actions setup (repository level)"
echo "=============================================="
echo "Go to: Settings → Secrets and variables → Actions"
echo ""
echo "--- 1. Repository SECRET (Add secret) ---"
echo "Name:  AWS_ROLE_ARN"
echo "Value: $ROLE_ARN"
echo ""
echo "--- 2. Repository VARIABLES (Add variable, repeat for each) ---"
echo "Name:  TF_STATE_BUCKET   Value: $BUCKET"
echo "Name:  TF_STATE_KEY     Value: $KEY"
echo "Name:  TF_LOCK_TABLE    Value: $TABLE"
echo ""
echo "--- 3. AWS Secrets Manager (one-time, for Claude on the box) ---"
echo "aws secretsmanager create-secret --name CLAUDE_API_KEY --secret-string \"YOUR_ANTHROPIC_KEY\" --region us-west-2"
echo ""
echo "--- 4. EC2 key pair ---"
echo "Ensure key pair 'dev-box' exists in us-west-2 (create in EC2 → Key Pairs if needed)."
echo "=============================================="
