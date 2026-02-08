#!/usr/bin/env bash
# userdata.sh — runs as root on first boot of the spot instance.
# Mounts persistent EBS, installs dev tooling, deploys dotfiles,
# installs Gastown + Claude Code.
set -euo pipefail

DEVICE="${ebs_device}"
MOUNT="${mount_point}"
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
# 5. Node (via nvm) — needed for Claude Code
# ==========================================================================
log "Installing nvm + Node LTS..."
sudo -iu "$DEV_USER" bash -c '
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts
'

# ==========================================================================
# 6. Claude Code (npm global)
# ==========================================================================
log "Installing Claude Code..."
sudo -iu "$DEV_USER" bash -c '
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  npm install -g @anthropic-ai/claude-code
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
# 8. Gastown
# ==========================================================================
log "Installing Gastown..."
sudo -iu "$DEV_USER" bash -c '
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  if [ ! -d "$HOME/.gastown" ]; then
    git clone https://github.com/steveyegge/gastown.git "$HOME/.gastown"
    cd "$HOME/.gastown"
    npm install
  fi
  # Add gt to PATH if not already
  if ! grep -q "gastown" "$HOME/.bashrc" 2>/dev/null; then
    echo "export PATH=\"\$HOME/.gastown/bin:\$PATH\"" >> "$HOME/.bash_profile_additions"
  fi
'

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
sudo -iu "$DEV_USER" bash -c "cat >> \$HOME/.bash_profile_additions << 'ADDITIONS'
# --- iac-dev-box additions (appended by userdata) ---

# Conda from persistent volume
if [ -f \"$MOUNT/miniforge3/etc/profile.d/conda.sh\" ]; then
  . \"$MOUNT/miniforge3/etc/profile.d/conda.sh\"
fi

# Gastown
export PATH=\"\$HOME/.gastown/bin:\$PATH\"

# NVM
export NVM_DIR=\"\$HOME/.nvm\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"

# Persistent volume workspace
export WORKSPACE=\"$MOUNT\"
ADDITIONS
"

# Source additions from .bashrc if not already wired up
sudo -iu "$DEV_USER" bash -c '
  if ! grep -q "bash_profile_additions" "$HOME/.bashrc" 2>/dev/null; then
    echo "" >> "$HOME/.bashrc"
    echo "# iac-dev-box: source persistent-volume additions" >> "$HOME/.bashrc"
    echo "[ -f \"\$HOME/.bash_profile_additions\" ] && . \"\$HOME/.bash_profile_additions\"" >> "$HOME/.bashrc"
  fi
'

log "--- iac-dev-box userdata complete ---"
