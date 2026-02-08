#!/usr/bin/env bash
# tf_init.sh — initialize Terraform with the S3 backend.
#
# You must provide backend config via env vars:
#   TF_STATE_BUCKET (required)
#   TF_STATE_KEY (required)
#   TF_STATE_REGION (required)
#   TF_LOCK_TABLE (required)
#
# Non-interactive state migration:
# - If Terraform detects it needs to migrate state (e.g. local -> S3, or backend config changed),
#   it normally prompts for approval. In automation we use -input=false, so you must opt in:
#     TF_INIT_FORCE_COPY=1 ./scripts/tf_init.sh
#
# WARNING: -force-copy will overwrite destination state without prompting.
# Only use it when you're sure you want to migrate.
#
# Example:
#   export TF_STATE_BUCKET="iac-dev-box-tfstate-YOUR_ACCOUNT_ID-us-west-2"
#   export TF_STATE_KEY="iac-dev-box/us-west-2/terraform.tfstate"
#   export TF_STATE_REGION="us-west-2"
#   export TF_LOCK_TABLE="iac-dev-box-tf-locks-YOUR_ACCOUNT_ID-us-west-2"
#   ./scripts/tf_init.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

missing=0
for v in TF_STATE_BUCKET TF_STATE_KEY TF_STATE_REGION TF_LOCK_TABLE; do
  if [ -z "${!v:-}" ]; then
    echo "Missing env var: $v" >&2
    missing=1
  fi
done
if [ "$missing" -eq 1 ]; then
  exit 2
fi

init_args=(
  -chdir="$REPO_DIR"
  init
  -input=false
  -reconfigure
  -backend-config="bucket=${TF_STATE_BUCKET}"
  -backend-config="key=${TF_STATE_KEY}"
  -backend-config="region=${TF_STATE_REGION}"
  -backend-config="dynamodb_table=${TF_LOCK_TABLE}"
  -backend-config="encrypt=true"
)

# If Terraform needs to migrate state, it prompts. In non-interactive mode, allow an explicit escape hatch.
if [ "${TF_INIT_FORCE_COPY:-}" = "1" ] || [ "${TF_INIT_FORCE_COPY:-}" = "true" ]; then
  init_args+=(-migrate-state -force-copy)
fi

exec terraform "${init_args[@]}" "$@"

