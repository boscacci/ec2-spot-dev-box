#!/usr/bin/env bash
# userdata.sh — runs as root on first boot of the spot instance.
# Mounts persistent EBS, installs dev tooling, deploys dotfiles,
# installs Gastown + Claude Code.
set -euo pipefail

DEVICE="${ebs_device}"
MOUNT="${mount_point}"
AWS_REGION="${aws_region}"
ENABLE_CLAUDE_SECRET="${enable_claude_secret}"
CLAUDE_SECRET_ID="${claude_api_key_secret_id}"
DEV_USER="ec2-user"
DEV_HOME="/home/$DEV_USER"

log() { echo "[userdata] $(date '+%H:%M:%S') $*"; }

# ==========================================================================
# 1. Persistent EBS volume
# ==========================================================================
log "Waiting for $DEVICE..."
for i in $(seq 1 60); do
  [ -b "$DEVICE" ] && break
  NVME_DEV=$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1) || true
  if [ -n "$NVME_DEV" ] && [ ! -b "$DEVICE" ]; then
    ln -sf "$NVME_DEV" "$DEVICE"
    break
  fi
  sleep 2
done

if [ ! -b "$DEVICE" ]; then
  log "ERROR: $DEVICE never appeared" >&2
  exit 1
fi

FSTYPE=$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)
if [ -z "$FSTYPE" ]; then
  log "Formatting $DEVICE as ext4 (first use)..."
  mkfs.ext4 -L devdata "$DEVICE"
fi

mkdir -p "$MOUNT"
mount "$DEVICE" "$MOUNT"

if ! grep -q "$MOUNT" /etc/fstab; then
  echo "LABEL=devdata $MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
fi

chown "$DEV_USER:$DEV_USER" "$MOUNT"
log "Persistent volume mounted at $MOUNT"

# ==========================================================================
# 2. System packages
# ==========================================================================
log "Installing system packages..."
dnf update -y
dnf install -y \
  git \
  curl \
  htop \
  tmux \
  jq \
  tar \
  gzip \
  unzip \
  gcc \
  make \
  openssl-devel \
  bzip2-devel \
  libffi-devel \
  zlib-devel \
  vim-enhanced

# ==========================================================================
# 3. Docker
# ==========================================================================
log "Installing Docker..."
dnf install -y docker
systemctl enable docker
systemctl start docker
usermod -aG docker "$DEV_USER"

# ==========================================================================
# 4. SSH agent forwarding support
# The instance never stores private keys. Your local ssh-agent is forwarded
# via `ssh -A` so git/ssh on the box can reach GitHub, GitLab, etc.
# ==========================================================================
log "Configuring SSH agent forwarding..."
# Ensure sshd allows agent forwarding (it does by default on AL2023, but be explicit)
if ! grep -q "^AllowAgentForwarding yes" /etc/ssh/sshd_config; then
  echo "AllowAgentForwarding yes" >> /etc/ssh/sshd_config
  systemctl restart sshd
fi

# ==========================================================================
# 5. Node (via nvm) — useful baseline for JS/TS dev
# ==========================================================================
log "Installing nvm + Node LTS..."
sudo -iu "$DEV_USER" bash -c '
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts
'

# ==========================================================================
# 6. Claude Code (official installer)
# ==========================================================================
log "Installing Claude Code..."
sudo -iu "$DEV_USER" bash -c '
  if ! command -v claude >/dev/null 2>&1; then
    curl -fsSL https://claude.ai/install.sh | bash
  fi
'

# ==========================================================================
# 7. Miniforge (conda) — installs to /data so it persists
# ==========================================================================
if [ ! -d "$MOUNT/miniforge3" ]; then
  log "Installing Miniforge to $MOUNT/miniforge3..."
  sudo -iu "$DEV_USER" bash -c "
    curl -fsSL https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -o /tmp/miniforge.sh
    bash /tmp/miniforge.sh -b -p $MOUNT/miniforge3
    $MOUNT/miniforge3/bin/conda init bash
    rm /tmp/miniforge.sh
  "
fi

# ==========================================================================
# 8. Go + Beads + Gas Town (gt)
# ==========================================================================
log "Installing Go toolchain..."
GO_VERSION="$(curl -fsSL https://go.dev/VERSION?m=text)"
if [ ! -x /usr/local/bin/go ] || ! /usr/local/bin/go version 2>/dev/null | grep -q "$GO_VERSION"; then
  curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
  rm /tmp/go.tgz
fi

log "Installing beads (bd) + gastown (gt)..."
sudo -iu "$DEV_USER" bash -c '
  export PATH="/usr/local/go/bin:$PATH"
  go install github.com/steveyegge/beads/cmd/bd@latest
  go install github.com/steveyegge/gastown/cmd/gt@latest
'

# Initialize a persistent Gas Town workspace on the EBS volume
log "Initializing Gas Town workspace..."
sudo -iu "$DEV_USER" bash -c "
  export PATH=\"/usr/local/go/bin:\$PATH\"
  export PATH=\"\$HOME/go/bin:\$PATH\"
  if [ ! -d \"$MOUNT/gt\" ]; then
    gt install \"$MOUNT/gt\" --git
  fi
  ln -sfn \"$MOUNT/gt\" \"\$HOME/gt\"
"

# ==========================================================================
# 9. Dotfiles from boscacci/rc
# Clone the rc repo and symlink dotfiles so the box feels like home.
# Uses SSH agent forwarding — if the agent isn't forwarded during userdata
# (it won't be), we fall back to HTTPS for the public repo.
# ==========================================================================
log "Deploying dotfiles from boscacci/rc..."
sudo -iu "$DEV_USER" bash -c '
  RC_DIR="$HOME/.rc"
  if [ ! -d "$RC_DIR" ]; then
    git clone https://github.com/boscacci/rc.git "$RC_DIR"
  else
    cd "$RC_DIR" && git pull --ff-only || true
  fi

  # Back up any existing dotfiles, then symlink
  for f in .bashrc .bash_aliases .bash_profile .vimrc; do
    if [ -f "$HOME/$f" ] && [ ! -L "$HOME/$f" ]; then
      mv "$HOME/$f" "$HOME/${f}.orig"
    fi
    ln -sf "$RC_DIR/$f" "$HOME/$f"
  done

  # Vundle
  mkdir -p "$HOME/.vim/bundle"
  if [ ! -d "$HOME/.vim/bundle/Vundle.vim" ]; then
    git clone https://github.com/VundleVim/Vundle.vim.git "$HOME/.vim/bundle/Vundle.vim"
  fi
  vim -N -u "$HOME/.vimrc" -i NONE +PluginInstall +qall 2>/dev/null || true
'

# Append persistent-volume-aware bits that the rc dotfiles don't know about
sudo -iu "$DEV_USER" bash -c "if ! grep -q \"iac-dev-box additions\" \$HOME/.bash_profile_additions 2>/dev/null; then cat >> \$HOME/.bash_profile_additions << 'ADDITIONS'
# --- iac-dev-box additions (appended by userdata) ---

# AWS region for tooling (Secrets Manager, Bedrock, etc.)
export AWS_REGION=\"$AWS_REGION\"

# Claude / Anthropic API key (pulled from AWS Secrets Manager via instance role)
# Secret id: $CLAUDE_SECRET_ID
_CLAUDE_ENV_FILE=\"$MOUNT/.secrets/claude.env\"
claude_key_refresh() {
  if [ \"${ENABLE_CLAUDE_SECRET}\" != \"true\" ] && [ \"${ENABLE_CLAUDE_SECRET}\" != \"1\" ]; then
    return 0
  fi
  command -v aws >/dev/null 2>&1 || return 0
  mkdir -p \"$MOUNT/.secrets\" 2>/dev/null || true
  umask 077
  local raw key
  raw=\"\$(aws --region \\\"$AWS_REGION\\\" secretsmanager get-secret-value --secret-id \\\"$CLAUDE_SECRET_ID\\\" --query SecretString --output text 2>/dev/null || true)\"
  [ -z \"\$raw\" ] && return 0
  key=\"\$raw\"
  if echo \"\$raw\" | jq -e . >/dev/null 2>&1; then
    key=\"\$(echo \"\$raw\" | jq -r '.CLAUDE_API_KEY // .ANTHROPIC_API_KEY // .api_key // .key // empty')\"
  fi
  [ -z \"\$key\" ] && return 0
  printf 'export ANTHROPIC_API_KEY=%q\\nexport CLAUDE_API_KEY=%q\\n' \"\$key\" \"\$key\" > \"\$_CLAUDE_ENV_FILE\"
}

if [ -z \"\${ANTHROPIC_API_KEY:-}\" ]; then
  # Refresh at most every 12 hours
  if [ ! -f \"\$_CLAUDE_ENV_FILE\" ] || [ \"\$(( \$(date +%s) - \$(stat -c %Y \"\$_CLAUDE_ENV_FILE\" 2>/dev/null || echo 0) ))\" -gt 43200 ]; then
    claude_key_refresh || true
  fi
  [ -f \"\$_CLAUDE_ENV_FILE\" ] && . \"\$_CLAUDE_ENV_FILE\"
fi

# Conda from persistent volume
if [ -f \"$MOUNT/miniforge3/etc/profile.d/conda.sh\" ]; then
  . \"$MOUNT/miniforge3/etc/profile.d/conda.sh\"
fi

# Go bins (for gt, bd, etc.)
export PATH=\"\$HOME/go/bin:\$PATH\"

# NVM
export NVM_DIR=\"\$HOME/.nvm\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"

# Persistent volume workspace
export WORKSPACE=\"$MOUNT\"
ADDITIONS
fi"

# Write per-machine bashrc hook without mutating the symlinked rc repo dotfiles.
# The rc repo's `.bashrc` sources `~/.bashrc.local` when present.
sudo -iu "$DEV_USER" bash -c '
  if ! grep -q "iac-dev-box additions" "$HOME/.bashrc.local" 2>/dev/null; then
    cat >> "$HOME/.bashrc.local" <<'"'"'EOF'"'"'

# --- iac-dev-box additions ---
[ -f "$HOME/.bash_profile_additions" ] && . "$HOME/.bash_profile_additions"

EOF
  fi
'

log "--- iac-dev-box userdata complete ---"
