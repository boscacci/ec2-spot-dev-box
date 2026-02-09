#!/usr/bin/env bash
# prepare_ssh_keys.sh - Helper to format SSH public keys for GitHub Secrets
# This script outputs your SSH public keys in the format needed for DEVBOX_ADDITIONAL_SSH_KEYS

set -euo pipefail

echo "=========================================="
echo "  SSH Keys for GitHub Secrets"
echo "=========================================="
echo ""
echo "This script will show your SSH public keys formatted for the"
echo "DEVBOX_ADDITIONAL_SSH_KEYS GitHub Secret."
echo ""
echo "Available SSH public keys on this system:"
echo ""

KEYS_FOUND=0

# Find all public keys in ~/.ssh/
for keyfile in ~/.ssh/*.pub; do
  if [ -f "$keyfile" ]; then
    echo "• $(basename "$keyfile")"
    ((KEYS_FOUND++))
  fi
done

if [ $KEYS_FOUND -eq 0 ]; then
  echo "No SSH public keys found in ~/.ssh/"
  echo ""
  echo "Generate a key with:"
  echo "  ssh-keygen -t rsa -b 4096 -C \"your_email@example.com\""
  exit 1
fi

echo ""
echo "=========================================="
echo "  Copy this content to GitHub Secret:"
echo "  DEVBOX_ADDITIONAL_SSH_KEYS"
echo "=========================================="
echo ""

# Output all public keys
for keyfile in ~/.ssh/*.pub; do
  if [ -f "$keyfile" ]; then
    cat "$keyfile"
  fi
done

echo ""
echo "=========================================="
echo "  Instructions:"
echo "=========================================="
echo ""
echo "1. Copy all the lines above (starting with 'ssh-rsa' or 'ssh-ed25519')"
echo "2. Go to your GitHub repo: Settings → Secrets and variables → Actions"
echo "3. Click 'New repository secret' (or 'New environment secret')"
echo "4. Name: DEVBOX_ADDITIONAL_SSH_KEYS"
echo "5. Value: Paste the keys you copied"
echo "6. Click 'Add secret'"
echo ""
echo "Done! Your SSH keys will be synced to new dev box instances."
