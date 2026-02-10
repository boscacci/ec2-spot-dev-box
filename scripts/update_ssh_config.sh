#!/usr/bin/env bash
# update_ssh_config.sh — update ~/.ssh/config Host dev-box entry with current IP
# from Terraform outputs so `ssh dev-box` stays stable even as spot IPs change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TF_DIR="$REPO_DIR/terraform"

HOST_ALIAS="${1:-dev-box}"
USER_NAME="${2:-ec2-user}"

IP="$(terraform -chdir="$TF_DIR" output -raw ssh_host 2>/dev/null || true)"
if [ -z "$IP" ]; then
  IP="$(terraform -chdir="$TF_DIR" output -raw public_ip 2>/dev/null || true)"
fi
KEY_NAME="$(terraform -chdir="$TF_DIR" output -raw key_name 2>/dev/null || true)"
INSTANCE_ID="$(terraform -chdir="$TF_DIR" output -raw instance_id 2>/dev/null || true)"

if [ -z "$IP" ]; then
  echo "No ssh_host/public_ip available. Is the box stopped (enable_instance=false)?" >&2
  exit 1
fi
if [ -z "$KEY_NAME" ]; then
  echo "Missing key_name output. Re-run 'terraform apply' and try again." >&2
  exit 1
fi
if [ -z "$INSTANCE_ID" ]; then
  echo "NOTE: instance_id is empty. The dev box is currently stopped (enable_instance=false). SSH will not connect until started." >&2
fi

SSH_DIR="$HOME/.ssh"
CFG_FILE="$SSH_DIR/config"
KEY_FILE="$SSH_DIR/${KEY_NAME}.pem"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR" 2>/dev/null || true

if [ ! -f "$KEY_FILE" ]; then
  echo "Key file not found: $KEY_FILE" >&2
  echo "Expected your EC2 keypair PEM to be named like: ~/.ssh/${KEY_NAME}.pem" >&2
  exit 1
fi

# Update HostName in the dev-box Host entry (or append if missing)
# Replace the host entry entirely so old insecure settings do not linger.
if grep -q "^Host $HOST_ALIAS$" "$CFG_FILE" 2>/dev/null; then
  TMP_FILE="$(mktemp)"
  awk -v host="$HOST_ALIAS" '
    BEGIN { skip = 0 }
    $1 == "Host" {
      if (skip == 1) {
        skip = 0
      }
      if ($0 == "Host " host) {
        skip = 1
        next
      }
    }
    {
      if (skip == 0) {
        print
      }
    }
  ' "$CFG_FILE" > "$TMP_FILE"
  mv "$TMP_FILE" "$CFG_FILE"
fi

cat >> "$CFG_FILE" <<EOF

Host $HOST_ALIAS
  HostName $IP
  Port 22
  User $USER_NAME
  IdentityFile $KEY_FILE
  ForwardAgent yes
  # Safer default: trust first key automatically, block unexpected key changes.
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ~/.ssh/known_hosts
  UpdateHostKeys yes
  LogLevel ERROR
  ServerAliveInterval 60
  ServerAliveCountMax 3
  IdentitiesOnly yes
  AddKeysToAgent yes
  HostKeyAlias $HOST_ALIAS
EOF

echo "Configured Host $HOST_ALIAS in $CFG_FILE (HostName=$IP, host key checking enabled)"
