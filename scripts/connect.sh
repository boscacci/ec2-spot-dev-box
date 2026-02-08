#!/usr/bin/env bash
# connect.sh — grab the public IP from Terraform output and SSH in with
# agent forwarding. Run from the repo root: ./scripts/connect.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$REPO_DIR"

./scripts/update_ssh_config.sh dev-box ec2-user >/dev/null

# Ensure the local ssh-agent has keys loaded
if ! ssh-add -l &>/dev/null; then
  echo "No keys in ssh-agent. Adding default keys..."
  ssh-add 2>/dev/null || true
fi

echo "Connecting to dev-box..."
exec ssh dev-box
