#!/usr/bin/env bash
# seed_dotfiles_once.sh — one-time copy of local bash dotfiles to the dev box's
# persistent rc directory (/data/opt/rc). After this, aliases survive respawns
# and are available even when connecting from phone.
#
# By default this syncs only files that are safe to layer onto the dev box:
#   - ~/.bash_aliases
#   - ~/.inputrc
#
# To also sync ~/.bashrc and ~/.bash_profile, set:
#   DEVBOX_SEED_FULL_BASH=1 ./scripts/seed_dotfiles_once.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

HOST="${1:-}"
USER_NAME="${2:-ec2-user}"
REMOTE_RC_DIR="/data/opt/rc"

if [ -z "$HOST" ]; then
  HOST="$(terraform -chdir="$REPO_DIR" output -raw ssh_host 2>/dev/null || true)"
fi
if [ -z "$HOST" ]; then
  echo "Could not resolve host. Pass it explicitly: ./scripts/seed_dotfiles_once.sh <host>" >&2
  exit 1
fi

KEY_NAME="$(terraform -chdir="$REPO_DIR" output -raw key_name 2>/dev/null || true)"
if [ -z "$KEY_NAME" ]; then
  echo "Missing key_name Terraform output." >&2
  exit 1
fi
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
if [ ! -f "$KEY_FILE" ]; then
  echo "Key file not found: $KEY_FILE" >&2
  exit 1
fi

if [ "${DEVBOX_SEED_FULL_BASH:-0}" = "1" ]; then
  LOCAL_FILES=(.bashrc .bash_aliases .bash_profile .inputrc)
else
  LOCAL_FILES=(.bash_aliases .inputrc)
fi
FILES_TO_SYNC=()
for f in "${LOCAL_FILES[@]}"; do
  if [ -f "$HOME/$f" ]; then
    FILES_TO_SYNC+=("$f")
  fi
done

if [ "${#FILES_TO_SYNC[@]}" -eq 0 ]; then
  echo "No local dotfiles found to sync (${LOCAL_FILES[*]})." >&2
  exit 0
fi

TMP_TAR="$(mktemp "/tmp/devbox-dotfiles-seed.XXXXXX.tar")"
cleanup() {
  rm -f "$TMP_TAR"
}
trap cleanup EXIT

tar -C "$HOME" -cf "$TMP_TAR" "${FILES_TO_SYNC[@]}"

SSH_OPTS=(
  -i "$KEY_FILE"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
  -o LogLevel=ERROR
)

scp "${SSH_OPTS[@]}" -q "$TMP_TAR" "$USER_NAME@$HOST:/tmp/devbox-dotfiles-seed.tar"
ssh "${SSH_OPTS[@]}" "$USER_NAME@$HOST" "set -euo pipefail; \
  sudo mkdir -p \"$REMOTE_RC_DIR\"; \
  sudo tar -xf /tmp/devbox-dotfiles-seed.tar -C \"$REMOTE_RC_DIR\"; \
  sudo rm -f /tmp/devbox-dotfiles-seed.tar; \
  sudo chown -R \"$USER_NAME:$USER_NAME\" \"$REMOTE_RC_DIR\"; \
  for f in ${LOCAL_FILES[*]}; do if [ -f \"$REMOTE_RC_DIR/\$f\" ]; then sudo chmod 644 \"$REMOTE_RC_DIR/\$f\"; fi; done; \
  if [ -f \"$REMOTE_RC_DIR/.bashrc\" ] && ! grep -q 'iac-dev-box additions' \"$REMOTE_RC_DIR/.bashrc\"; then \
    printf '\n# --- iac-dev-box additions ---\nif [ -f \"\$HOME/.bash_aliases\" ]; then\n  . \"\$HOME/.bash_aliases\"\nfi\nif [ -f \"\$HOME/.bash_profile_additions\" ]; then\n  . \"\$HOME/.bash_profile_additions\"\nfi\n' | sudo tee -a \"$REMOTE_RC_DIR/.bashrc\" >/dev/null; \
  fi"

echo "Seeded ${#FILES_TO_SYNC[@]} dotfile(s) to $USER_NAME@$HOST:$REMOTE_RC_DIR"
