#!/usr/bin/env bash
# userdata.sh — runs as root at instance boot.
# Goals:
# - Mount the persistent EBS volume at /data
# - Keep boot idempotent (safe to rerun)
# - Install heavy tooling once onto /data, so spot replacements boot fast
set -euo pipefail

DEVICE="${ebs_device}"
MOUNT="${mount_point}"
AWS_REGION="${aws_region}"
ENABLE_CLAUDE_SECRET="${enable_claude_secret}"
CLAUDE_SECRET_ID="${claude_api_key_secret_id}"
CLAUDE_SECRET_REGION="${claude_secret_region}"
ENABLE_EIP="${enable_eip}"
EIP_ALLOCATION_ID="${eip_allocation_id}"
ADDITIONAL_SSH_KEYS="${additional_ssh_keys}"
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

# --------------------------------------------------------------------------
# Bootstrap marker (lives on /data, survives spot terminations)
# --------------------------------------------------------------------------
BOOTSTRAP_DIR="$MOUNT/.iac-dev-box"
BOOTSTRAP_MARKER="$BOOTSTRAP_DIR/bootstrap-v1"
FORCE_BOOTSTRAP="$BOOTSTRAP_DIR/force-bootstrap"

mkdir -p "$BOOTSTRAP_DIR" "$MOUNT/bin" "$MOUNT/opt" "$MOUNT/home/$DEV_USER"
mkdir -p "$MOUNT/home/$DEV_USER/.nvm"
chown -R "$DEV_USER:$DEV_USER" "$MOUNT/bin" "$MOUNT/opt" "$MOUNT/home/$DEV_USER" || true
chmod 700 "$MOUNT/home/$DEV_USER" || true

FIRST_BOOT=0
if [ ! -f "$BOOTSTRAP_MARKER" ] || [ -f "$FORCE_BOOTSTRAP" ]; then
  FIRST_BOOT=1
fi

log "Bootstrap marker: $BOOTSTRAP_MARKER (first_boot=$FIRST_BOOT)"

# ==========================================================================
# 2. System packages (per-instance; keep minimal, avoid full updates)
# ==========================================================================
log "Installing base system packages..."
dnf install -y --allowerasing \
  git \
  curl-minimal \
  jq \
  tmux \
  htop \
  tar \
  gzip \
  unzip \
  vim-enhanced \
  awscli \
  docker

# sqlite package naming varies slightly; best-effort
dnf install -y sqlite || dnf install -y sqlite3 || true

# ==========================================================================
# 3. Docker
# ==========================================================================
log "Installing Docker..."
systemctl enable docker
systemctl start docker
usermod -aG docker "$DEV_USER"

# ==========================================================================
# 3.5 Elastic IP association (stable endpoint)
# ==========================================================================
if [ "$ENABLE_EIP" = "true" ] || [ "$ENABLE_EIP" = "1" ]; then
  if [ -n "$EIP_ALLOCATION_ID" ] && command -v aws >/dev/null 2>&1; then
    log "Associating Elastic IP (allocation_id=$EIP_ALLOCATION_ID)..."
    TOKEN="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
    IID="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/instance-id" || true)"
    if [ -n "$IID" ]; then
      aws --region "$AWS_REGION" ec2 associate-address --allocation-id "$EIP_ALLOCATION_ID" --instance-id "$IID" --allow-reassociation >/dev/null 2>&1 || true
    fi
  fi
fi

# ==========================================================================
# 3.6 Idle auto-terminate (90 minutes)
# ==========================================================================
log "Configuring idle auto-shutdown (90 minutes)..."
cat > /usr/local/sbin/devbox-idle-shutdown <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MOUNT="/data"
STATE_DIR="$MOUNT/.iac-dev-box"
LAST_ACTIVE_FILE="$STATE_DIR/last_active_epoch"
IDLE_SECS=5400 # 90 minutes

mkdir -p "$STATE_DIR"

now="$(date +%s)"

active=0

# "Activity" heuristics for a dev box (rough but practical):
# - any logged-in user session
# - any running docker container
# - load average suggests something is happening
if who | grep -q .; then
  active=1
fi
if command -v docker >/dev/null 2>&1 && docker ps -q 2>/dev/null | grep -q .; then
  active=1
fi
load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
if awk -v l="$load1" 'BEGIN { exit !(l+0.0 > 0.20) }'; then
  active=1
fi

if [ "$active" -eq 1 ]; then
  echo "$now" > "$LAST_ACTIVE_FILE"
  exit 0
fi

if [ ! -f "$LAST_ACTIVE_FILE" ]; then
  echo "$now" > "$LAST_ACTIVE_FILE"
  exit 0
fi

last="$(cat "$LAST_ACTIVE_FILE" 2>/dev/null || echo 0)"
idle="$((now - last))"
if [ "$idle" -ge "$IDLE_SECS" ]; then
  logger -t devbox-idle "Idle for $idle s (>=$IDLE_SECS s). Shutting down."
  shutdown -h now "iac-dev-box: idle for 90 minutes; shutting down to save money."
fi
EOF
chmod 755 /usr/local/sbin/devbox-idle-shutdown

cat > /etc/systemd/system/devbox-idle-shutdown.service <<'EOF'
[Unit]
Description=Dev box idle auto-shutdown

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/devbox-idle-shutdown
EOF

cat > /etc/systemd/system/devbox-idle-shutdown.timer <<'EOF'
[Unit]
Description=Run dev box idle check periodically

[Timer]
OnBootSec=10min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now devbox-idle-shutdown.timer >/dev/null 2>&1 || true

# ==========================================================================
# 4. SSH agent forwarding support
# The instance never stores private keys. Your local ssh-agent is forwarded
# via `ssh -A` so git/ssh on the box can reach GitHub, GitLab, etc.
# ==========================================================================
log "Configuring SSH agent forwarding..."
# Keep host keys stable across spot replacements by persisting them on /data.
# This allows strict host key checking without frequent lockouts.
SSH_HOSTKEY_DIR="$BOOTSTRAP_DIR/ssh-host-keys"
mkdir -p "$SSH_HOSTKEY_DIR"

if compgen -G "$SSH_HOSTKEY_DIR/ssh_host_*_key" >/dev/null; then
  log "Restoring persisted SSH host keys from $SSH_HOSTKEY_DIR"
  cp -f "$SSH_HOSTKEY_DIR"/ssh_host_*_key /etc/ssh/
  cp -f "$SSH_HOSTKEY_DIR"/ssh_host_*_key.pub /etc/ssh/
  chown root:root /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
  chmod 600 /etc/ssh/ssh_host_*_key
  chmod 644 /etc/ssh/ssh_host_*_key.pub
  systemctl restart sshd
else
  log "Persisting initial SSH host keys to $SSH_HOSTKEY_DIR"
  cp -f /etc/ssh/ssh_host_*_key "$SSH_HOSTKEY_DIR"/
  cp -f /etc/ssh/ssh_host_*_key.pub "$SSH_HOSTKEY_DIR"/
  chown root:root "$SSH_HOSTKEY_DIR"/ssh_host_*_key "$SSH_HOSTKEY_DIR"/ssh_host_*_key.pub
  chmod 600 "$SSH_HOSTKEY_DIR"/ssh_host_*_key
  chmod 644 "$SSH_HOSTKEY_DIR"/ssh_host_*_key.pub
fi

# Ensure sshd allows agent forwarding (it does by default on AL2023, but be explicit)
if ! grep -q "^AllowAgentForwarding yes" /etc/ssh/sshd_config; then
  echo "AllowAgentForwarding yes" >> /etc/ssh/sshd_config
  systemctl restart sshd
fi

# ==========================================================================
# 4.5 Add additional SSH public keys from Terraform
# ==========================================================================
if [ -n "$ADDITIONAL_SSH_KEYS" ]; then
  log "Adding additional SSH public keys to authorized_keys..."
  mkdir -p "$DEV_HOME/.ssh"
  chmod 700 "$DEV_HOME/.ssh"
  
  # Append keys if they don't already exist
  echo "$ADDITIONAL_SSH_KEYS" | while IFS= read -r key; do
    if [ -n "$key" ] && ! grep -qF "$key" "$DEV_HOME/.ssh/authorized_keys" 2>/dev/null; then
      echo "$key" >> "$DEV_HOME/.ssh/authorized_keys"
    fi
  done
  
  chmod 600 "$DEV_HOME/.ssh/authorized_keys"
  chown -R "$DEV_USER:$DEV_USER" "$DEV_HOME/.ssh"
fi

# ==========================================================================
# System-wide PATH for dev box tools (claude, gt, bd) — runs on every login
# ==========================================================================
log "Configuring system PATH for dev box tools..."
cat > /etc/profile.d/iac-dev-box.sh <<'PROFILE'
# iac-dev-box: claude, gt, bd, Go on PATH for every login
[ -d /data/bin ] && export PATH="/data/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
[ -d /data/opt/go/bin ] && export PATH="/data/opt/go/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
PROFILE
chmod 644 /etc/profile.d/iac-dev-box.sh

# --------------------------------------------------------------------------
# Persistent-home symlinks (per-instance wiring; fast)
# --------------------------------------------------------------------------
if [ ! -e "$DEV_HOME/.nvm" ]; then
  ln -s "$MOUNT/home/$DEV_USER/.nvm" "$DEV_HOME/.nvm" || true
fi
if [ ! -e "$DEV_HOME/.vim" ]; then
  ln -s "$MOUNT/home/$DEV_USER/.vim" "$DEV_HOME/.vim" || true
fi
mkdir -p "$MOUNT/home/$DEV_USER/.vim" "$MOUNT/home/$DEV_USER/.vim/bundle"
chown -R "$DEV_USER:$DEV_USER" "$MOUNT/home/$DEV_USER/.vim" "$MOUNT/home/$DEV_USER/.nvm" 2>/dev/null || true

# If Go was installed previously on /data, wire it into /usr/local for this instance
if [ -d "$MOUNT/opt/go" ]; then
  ln -sfn "$MOUNT/opt/go" /usr/local/go
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
fi

# --------------------------------------------------------------------------
# Heavy installs (only when the /data bootstrap marker is missing)
# --------------------------------------------------------------------------
if [ "$FIRST_BOOT" -eq 1 ]; then
  log "First boot: performing one-time installs onto $MOUNT..."

  # Miniforge (conda) to /data so envs persist
  if [ ! -d "$MOUNT/miniforge3" ]; then
    log "Installing Miniforge to $MOUNT/miniforge3..."
    sudo -iu "$DEV_USER" bash -c "set -euo pipefail; curl -fsSL https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -o /tmp/miniforge.sh; bash /tmp/miniforge.sh -b -p $MOUNT/miniforge3; rm /tmp/miniforge.sh"
  fi
  
  # Create 'sr' conda environment with Jupyter and pandas
  if [ ! -d "$MOUNT/miniforge3/envs/sr" ]; then
    log "Creating 'sr' conda environment with Jupyter and pandas..."
    sudo -iu "$DEV_USER" bash -c "set -euo pipefail; source $MOUNT/miniforge3/etc/profile.d/conda.sh; conda create -y -n sr python=3.11 jupyter jupyterlab pandas numpy matplotlib seaborn scikit-learn ipython"
  fi

  # Go toolchain to /data/opt/go
  log "Installing Go toolchain to $MOUNT/opt/go..."
  GO_VERSION="$(curl -fsSL https://go.dev/VERSION?m=text | head -n 1)"
  if [ ! -x "$MOUNT/opt/go/bin/go" ] || ! "$MOUNT/opt/go/bin/go" version 2>/dev/null | grep -q "$GO_VERSION"; then
    curl -fsSL "https://go.dev/dl/$GO_VERSION.linux-amd64.tar.gz" -o /tmp/go.tgz
    rm -rf "$MOUNT/opt/go"
    tar -C "$MOUNT/opt" -xzf /tmp/go.tgz
    rm /tmp/go.tgz
  fi
  ln -sfn "$MOUNT/opt/go" /usr/local/go
  ln -sf /usr/local/go/bin/go /usr/local/bin/go
  ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

  # beads + gt into /data/bin
  # Note: `go install ...@latest` can fail if upstream modules use replace directives.
  # Build from a checkout (as the main module) instead.
  log "Installing beads (bd) + gastown (gt) into $MOUNT/bin..."
  sudo -iu "$DEV_USER" bash -c "set -euo pipefail; export PATH=\"$MOUNT/opt/go/bin:\$PATH\"; mkdir -p \"$MOUNT/bin\" \"$MOUNT/src\"; \
    if [ ! -d \"$MOUNT/src/beads/.git\" ]; then git clone --depth 1 https://github.com/steveyegge/beads.git \"$MOUNT/src/beads\"; fi; \
    if [ ! -x \"$MOUNT/bin/bd\" ]; then (cd \"$MOUNT/src/beads\" && go build -o \"$MOUNT/bin/bd\" ./cmd/bd); fi; \
    if [ ! -d \"$MOUNT/src/gastown/.git\" ]; then git clone --depth 1 https://github.com/steveyegge/gastown.git \"$MOUNT/src/gastown\"; fi; \
    if [ ! -x \"$MOUNT/bin/gt\" ]; then (cd \"$MOUNT/src/gastown\" && go build -o \"$MOUNT/bin/gt\" ./cmd/gt); fi; \
    chmod 755 \"$MOUNT/bin/bd\" \"$MOUNT/bin/gt\""

  # Initialize a persistent Gas Town workspace on /data
  log "Initializing Gas Town workspace on $MOUNT/gt..."
  sudo -iu "$DEV_USER" bash -c "set -euo pipefail; export PATH=\"$MOUNT/bin:$MOUNT/opt/go/bin:\$PATH\"; if [ ! -d \"$MOUNT/gt\" ]; then gt install \"$MOUNT/gt\" --git; fi"

  # nvm + Node LTS into /data-backed home
  log "Installing nvm + Node LTS (persistent on $MOUNT)..."
  sudo -iu "$DEV_USER" bash -c "set -euo pipefail; mkdir -p \"$DEV_HOME/.nvm\"; if [ ! -s \"$DEV_HOME/.nvm/nvm.sh\" ]; then curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash; fi; . \"$DEV_HOME/.nvm/nvm.sh\"; nvm install --lts"

  # Claude Code: install once, then copy binary into /data/bin
  log "Installing Claude Code (one-time)..."
  if [ ! -x "$MOUNT/bin/claude" ]; then
    sudo -iu "$DEV_USER" bash -c "set -euo pipefail; if ! command -v claude >/dev/null 2>&1; then curl -fsSL https://claude.ai/install.sh | bash; fi; CLAUDE_BIN=\$(command -v claude || true); if [ -n \"\$CLAUDE_BIN\" ]; then cp -f \"\$CLAUDE_BIN\" \"$MOUNT/bin/claude\"; chmod 755 \"$MOUNT/bin/claude\"; fi"
  fi

  # Dotfiles: install a bundled minimal set onto /data (no external git auth required)
  # NOTE: We intentionally do NOT `git clone` your dotfiles repo here because it may be private.
  RC_DIR="$MOUNT/opt/rc"
  log "Installing bundled dotfiles into $RC_DIR..."
  mkdir -p "$RC_DIR"
  chown -R "$DEV_USER:$DEV_USER" "$RC_DIR" || true

  if [ ! -f "$RC_DIR/.bash_profile" ]; then
    cat > "$RC_DIR/.bash_profile" <<'EOF'
# ~/.bash_profile (dev-box)
if [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi
EOF
  fi

  if [ ! -f "$RC_DIR/.bash_aliases" ]; then
    cat > "$RC_DIR/.bash_aliases" <<'EOF'
# ~/.bash_aliases (dev-box)
alias ll='ls -FAlh --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias c='clear'
EOF
  fi

  if [ ! -f "$RC_DIR/.bashrc" ]; then
    cat > "$RC_DIR/.bashrc" <<EOF
# ~/.bashrc (dev-box)

# Interactive shells only
case $- in
  *i*) ;;
  *) return ;;
esac

# Dev box tools (claude, gt, bd) and Go — available on every login
export PATH="/data/bin:/data/opt/go/bin:\$HOME/.local/bin:\$PATH"

if [ -f "\$HOME/.bash_aliases" ]; then
  . "\$HOME/.bash_aliases"
fi

if [ -f "\$HOME/.bash_secrets" ]; then
  . "\$HOME/.bash_secrets"
fi

# Conda (prefer persistent /data install)
if [ -f "/data/miniforge3/etc/profile.d/conda.sh" ]; then
  . "/data/miniforge3/etc/profile.d/conda.sh"
  conda activate sr 2>/dev/null || true
fi

# NVM
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"

# Prompt
PS1='[\u@\h \w]\n| => '

# Local per-machine overrides (not tracked)
if [ -f "\$HOME/.bashrc.local" ]; then
  . "\$HOME/.bashrc.local"
fi
EOF
  fi

  if [ ! -f "$RC_DIR/.vimrc" ]; then
    cat > "$RC_DIR/.vimrc" <<'EOF'
syntax enable

set number
set relativenumber
set hlsearch
set encoding=utf8
set ts=4
set shiftwidth=4
set autoindent
set autoread
set backspace=eol,start,indent
set whichwrap+=<,>,h,l
set cursorline
set showmatch
let python_highlight_all = 1

set nocompatible
filetype off
filetype indent on

set rtp+=~/.vim/bundle/Vundle.vim
call vundle#begin()
Plugin 'VundleVim/Vundle.vim'
Plugin 'vim-airline/vim-airline'
call vundle#end()
EOF
  fi

  if [ ! -f "$RC_DIR/.bash_secrets.example" ]; then
    cat > "$RC_DIR/.bash_secrets.example" <<'EOF'
# ~/.bash_secrets (EXAMPLE)
# Copy to ~/.bash_secrets and chmod 600.
#
# export GITLAB_TOKEN="REPLACE_ME"
# export SOME_API_KEY="REPLACE_ME"
EOF
  fi

  chown -R "$DEV_USER:$DEV_USER" "$RC_DIR" || true

  # Vim plugins (persist on /data)
  log "Installing Vundle and vim plugins (one-time)..."
  sudo -iu "$DEV_USER" bash -c "set -euo pipefail; mkdir -p \"$DEV_HOME/.vim/bundle\"; if [ ! -d \"$DEV_HOME/.vim/bundle/Vundle.vim\" ]; then git clone https://github.com/VundleVim/Vundle.vim.git \"$DEV_HOME/.vim/bundle/Vundle.vim\"; fi; if [ -f \"$MOUNT/opt/rc/.vimrc\" ]; then ln -sf \"$MOUNT/opt/rc/.vimrc\" \"$DEV_HOME/.vimrc\"; fi; vim -N -u \"$DEV_HOME/.vimrc\" -i NONE +PluginInstall +qall 2>/dev/null || true"

  date -Iseconds > "$BOOTSTRAP_MARKER"
  rm -f "$FORCE_BOOTSTRAP" || true
  log "Bootstrap complete."
else
  log "Bootstrap marker present; skipping one-time installs."
fi

# --------------------------------------------------------------------------
# Always-on wiring (works for every fresh instance)
# --------------------------------------------------------------------------
sudo -iu "$DEV_USER" bash -c "set -eo pipefail; ln -sfn \"$MOUNT/gt\" \"$DEV_HOME/gt\"; ln -sfn \"$MOUNT/opt/rc\" \"$DEV_HOME/.rc\"; for f in .bashrc .bash_aliases .bash_profile .vimrc; do if [ -f \"$MOUNT/opt/rc/\$f\" ]; then if [ -f \"$DEV_HOME/\$f\" ] && [ ! -L \"$DEV_HOME/\$f\" ]; then mv \"$DEV_HOME/\$f\" \"$DEV_HOME/\$f.orig\" || true; fi; ln -sf \"$MOUNT/opt/rc/\$f\" \"$DEV_HOME/\$f\"; fi; done"

# Append persistent-volume-aware bits (expand MOUNT/paths at userdata time so they work at login)
sudo -iu "$DEV_USER" bash -c "if ! grep -q \"iac-dev-box additions\" \$HOME/.bash_profile_additions 2>/dev/null; then cat >> \$HOME/.bash_profile_additions << ADDITIONS
# --- iac-dev-box additions (appended by userdata) ---

# Persistent tool paths (claude, gt, bd in /data/bin)
export AWS_REGION=\"$AWS_REGION\"
export CLAUDE_SECRET_REGION=\"$CLAUDE_SECRET_REGION\"
export PATH=\"$MOUNT/bin:$MOUNT/opt/go/bin:\$PATH\"

# Claude Code / Anthropic API key (from AWS Secrets Manager via instance role)
# See https://docs.anthropic.com/en/docs/build-with-claude
claude_key_refresh() {
  if [ \"$ENABLE_CLAUDE_SECRET\" != \"true\" ] && [ \"$ENABLE_CLAUDE_SECRET\" != \"1\" ]; then
    return 0
  fi
  if [ -n \"\$ANTHROPIC_API_KEY\" ]; then
    return 0
  fi
  command -v aws >/dev/null 2>&1 || return 0
  local raw key
  raw=\"\$(aws --region \"$CLAUDE_SECRET_REGION\" secretsmanager get-secret-value --secret-id \"$CLAUDE_SECRET_ID\" --query SecretString --output text 2>/dev/null || true)\"
  [ -z \"\$raw\" ] && return 0
  key=\"\$raw\"
  if echo \"\$raw\" | jq -e . >/dev/null 2>&1; then
    key=\"\$(echo \"\$raw\" | jq -r '.CLAUDE_API_KEY // .ANTHROPIC_API_KEY // .api_key // .key // empty')\"
  fi
  [ -z \"\$key\" ] && return 0
  export ANTHROPIC_API_KEY=\"\$key\"
  export CLAUDE_API_KEY=\"\$key\"
}
claude_key_refresh || true

# Conda from persistent volume
if [ -f \"$MOUNT/miniforge3/etc/profile.d/conda.sh\" ]; then
  . \"$MOUNT/miniforge3/etc/profile.d/conda.sh\"
fi

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
