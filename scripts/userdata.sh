#!/usr/bin/env bash
# userdata.sh — runs as root on first boot of the spot instance.
# Mounts the persistent EBS volume and installs baseline dev tooling.
set -euo pipefail

DEVICE="${ebs_device}"
MOUNT="${mount_point}"

# ---------- Wait for the EBS volume to appear ----------
echo "Waiting for $DEVICE to appear..."
for i in $(seq 1 60); do
  [ -b "$DEVICE" ] && break
  # NVMe-backed instances expose volumes as /dev/nvme*
  # symlink the first non-root nvme device if /dev/xvdf isn't there
  NVME_DEV=$(lsblk -dpno NAME | grep nvme | grep -v nvme0n1 | head -1) || true
  if [ -n "$NVME_DEV" ] && [ ! -b "$DEVICE" ]; then
    ln -sf "$NVME_DEV" "$DEVICE"
    break
  fi
  sleep 2
done

if [ ! -b "$DEVICE" ]; then
  echo "ERROR: $DEVICE never appeared after 120s" >&2
  exit 1
fi

# ---------- Format only if not already formatted ----------
FSTYPE=$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)
if [ -z "$FSTYPE" ]; then
  echo "Formatting $DEVICE as ext4 (first use)..."
  mkfs.ext4 -L devdata "$DEVICE"
fi

# ---------- Mount ----------
mkdir -p "$MOUNT"
mount "$DEVICE" "$MOUNT"

# Persist across reboots (idempotent)
if ! grep -q "$MOUNT" /etc/fstab; then
  echo "LABEL=devdata $MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
fi

# Give ec2-user ownership
chown ec2-user:ec2-user "$MOUNT"

echo "Persistent volume mounted at $MOUNT"

# ---------- Install baseline dev tooling ----------
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
  zlib-devel

# Docker
dnf install -y docker
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# Node (via nvm, installed for ec2-user)
sudo -iu ec2-user bash -c '
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts
'

# Miniforge (conda) for ec2-user — installs into /data/miniforge3 so it persists
if [ ! -d "$MOUNT/miniforge3" ]; then
  sudo -iu ec2-user bash -c "
    curl -fsSL https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -o /tmp/miniforge.sh
    bash /tmp/miniforge.sh -b -p $MOUNT/miniforge3
    $MOUNT/miniforge3/bin/conda init bash
    rm /tmp/miniforge.sh
  "
fi

echo "--- dev-box userdata complete ---"
