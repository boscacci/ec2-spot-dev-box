#!/usr/bin/env bash
# update_ssh_config.sh — update ~/.ssh/config Host dev-box entry with current IP
# from Terraform outputs so `ssh dev-box` stays stable even as spot IPs change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

HOST_ALIAS="${1:-dev-box}"
USER_NAME="${2:-ec2-user}"

IP="$(terraform -chdir="$REPO_DIR" output -raw ssh_host 2>/dev/null || true)"
if [ -z "$IP" ]; then
  IP="$(terraform -chdir="$REPO_DIR" output -raw public_ip 2>/dev/null || true)"
fi
KEY_NAME="$(terraform -chdir="$REPO_DIR" output -raw key_name 2>/dev/null || true)"
INSTANCE_ID="$(terraform -chdir="$REPO_DIR" output -raw instance_id 2>/dev/null || true)"

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
if grep -q "^Host $HOST_ALIAS$" "$CFG_FILE" 2>/dev/null; then
  # Host entry exists; update HostName line
  sed -i "/^Host $HOST_ALIAS$/,/^Host / { s|^  HostName .*|  HostName $IP|; }" "$CFG_FILE"
  echo "Updated HostName=$IP in $CFG_FILE"
else
  # Host entry missing; append it
  cat >> "$CFG_FILE" <<EOF

Host $HOST_ALIAS
  HostName $IP
  Port 22
  User $USER_NAME
  IdentityFile $KEY_FILE
  ForwardAgent yes
  # Disposable box: instances get replaced behind a stable IP, so host keys churn.
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ServerAliveInterval 60
  ServerAliveCountMax 3
  IdentitiesOnly yes
  AddKeysToAgent yes
  HostKeyAlias $HOST_ALIAS
EOF
  echo "Added Host $HOST_ALIAS to $CFG_FILE (HostName=$IP)"
fi
