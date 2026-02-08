#!/usr/bin/env bash
# connect.sh — grab the public IP from Terraform output and SSH in with
# agent forwarding. Run from the repo root: ./scripts/connect.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$REPO_DIR"

# Pull the IP and key name from Terraform outputs
IP=$(terraform output -raw public_ip 2>/dev/null)
KEY_NAME=$(terraform output -json ssh_command 2>/dev/null | grep -oP '~/.ssh/\K[^.]+' || true)

if [ -z "$IP" ]; then
  echo "No running instance found. Run 'terraform apply' first." >&2
  exit 1
fi

KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
if [ ! -f "$KEY_FILE" ]; then
  echo "Key file not found: $KEY_FILE" >&2
  echo "Make sure your EC2 key pair PEM is at that path." >&2
  exit 1
fi

# Ensure the local ssh-agent has keys loaded
if ! ssh-add -l &>/dev/null; then
  echo "No keys in ssh-agent. Adding default keys..."
  ssh-add 2>/dev/null || true
fi

echo "Connecting to dev-box at $IP with agent forwarding..."
exec ssh -A -i "$KEY_FILE" \
  -o StrictHostKeyChecking=accept-new \
  -o ServerAliveInterval=60 \
  "ec2-user@$IP"
