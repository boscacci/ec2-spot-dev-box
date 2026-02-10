#!/usr/bin/env bash
# plan.sh — show spot prices, then run terraform plan.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TF_DIR="$REPO_DIR/terraform"

"$REPO_DIR/scripts/prices.sh" || true
echo
exec terraform -chdir="$TF_DIR" plan "$@"
