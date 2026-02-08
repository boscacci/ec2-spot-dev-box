#!/usr/bin/env bash
# apply.sh — show spot vs on-demand savings, then terraform apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

"$REPO_DIR/scripts/prices.sh" || true
echo
exec terraform -chdir="$REPO_DIR" apply "$@"

