# ec2-spot-dev-box

**Ephemeral EC2 spot dev environment with persistent storage, phone control, and auto-shutdown to save money.**

Terraform IaC for spinning up disposable dev boxes on AWS Spot instances with a persistent `/data` EBS volume and Elastic IP for stable SSH access. Start/stop from your phone via GitHub Actions—pay only for what you use.

---

## ✨ Key Features

- 📱 **Phone control** — Start/stop from GitHub Actions mobile app with L/M/H/XL instance sizes
- 💰 **Spot savings** — 60–70% cheaper than on-demand; auto-shutdown after 90 min idle to cut costs further
- 💾 **Persistent data** — `/data` EBS survives spot interruptions; your work and repos stay put
- 🔑 **SSH-first** — Your local SSH keys auto-synced; git credentials never touch the instance
- 🤖 **Claude ready** — Anthropic API key injected from AWS Secrets Manager on boot
- 📊 **Data science stack** — Jupyter, pandas, numpy, scikit-learn in `sr` conda env
- ⚡ **Fast boots** — Heavy tooling cached on `/data`; subsequent boots take ~30s
- 🪶 **Lightweight control** — OIDC auth (no long-lived AWS keys); S3 + DynamoDB for remote state

---

## Flavors

| Name   | Instance Type | vCPU | RAM   | Price/hr | Use case |
|--------|---|---|---|---|---|
| small  | t3.large      | 2  | 8 GB  | ~$0.05 | Cheap dev |
| medium | m7i.xlarge    | 4  | 16 GB | ~$0.08 | General purpose |
| large  | r7i.xlarge    | 4  | 32 GB | ~$0.15 | Memory-heavy |
| xl     | r7i.2xlarge   | 8  | 64 GB | ~$0.30 | Heavy compute |

---

## What You Get

**Architecture:**
- **Spot compute** (ephemeral, interruptible) + **persistent EBS** (96 GB gp3, survives everything)
- **Elastic IP** — stable endpoint for phone SSH and repeated connects
- **Bootstrap marker** — idempotent re-runs; first boot takes ~3 min, subsequent ~30s
- **Host key persistence** — SSH host keys live on `/data`; spot replacement keeps same identity

**Included tools:**
- Docker
- Claude Code / Anthropic SDK
- Miniforge (conda) with `sr` data science env
- Node.js (nvm)
- Git + SSH agent forwarding (no credentials stored locally)
- Vim + Vundle plugins
- AWS CLI, Terraform, jq

**Auto-features:**
- Idle detection (login sessions, docker containers, load avg) → auto-shutdown after 90 min
- Safe host key checking (`StrictHostKeyChecking accept-new`) — blocks MITM while allowing first-connect
- Automatic Elastic IP re-association on boot

---

## Quick Start

### 1. Prerequisites

```bash
# Local: Terraform, SSH keys, AWS creds
terraform version  # >= 1.5
aws sts get-caller-identity
ssh-keygen -t ed25519 -f ~/.ssh/dev-box -C "dev-box key"
```

### 2. Bootstrap (one-time)

Creates S3 state bucket, DynamoDB lock table, and GitHub OIDC role.

```bash
cd bootstrap
terraform init
terraform apply
```

Save these outputs for GitHub:
- `gha_terraform_role_arn`
- `tf_state_bucket`
- `tf_lock_table`
- `tf_state_key`

### 3. Configure GitHub (one-time)

From repo root:
```bash
./scripts/github_setup_from_bootstrap.sh
```

Add the printed secret + 3 variables in **Settings → Secrets and variables → Actions**:
- **1 secret:** `AWS_ROLE_ARN`
- **3 variables:** `TF_STATE_BUCKET`, `TF_STATE_KEY`, `TF_LOCK_TABLE`

### 4. Create local Terraform vars

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: set key_name, ssh_public_key_path, allowed_ssh_cidrs
```

### 5. One-time dotfile seed (recommended)

Run once from your WSL/laptop to copy your local bash dotfiles into `/data/opt/rc`:

```bash
./scripts/seed_dotfiles_once.sh
```

This makes aliases like `ll` persist across respawns and available even when you later connect from phone.

### 6. Start from phone

GitHub mobile app → **Actions** → **dev-box** → **Run workflow**
- **action:** `start`
- **flavor:** `Large` (or leave blank to keep current)

Wait ~2–3 min. SSH host will appear in workflow output.

---

## Usage

### Connect via SSH

```bash
# Get host (or use Actions output)
terraform output -raw ssh_host
ssh -i ~/.ssh/dev-box.pem ec2-user@<ip>
```

If your key file uses a different name, replace `~/.ssh/dev-box.pem` accordingly.

### Check pricing (spot vs on-demand)

```bash
./scripts/prices.sh
```

### Stop without destroying data

```bash
terraform apply -auto-approve -var="enable_instance=false"
```

### Verify setup on the box

```bash
# SSH'd in:
curl -fsSL https://raw.githubusercontent.com/boscacci/ec2-spot-dev-box/main/scripts/verify_setup.sh | bash
```

### Persistent repos

Your git credentials never touch the instance (SSH agent forwarding via `ssh -A`).

```bash
mkdir -p /data/repos
cd /data/repos
git clone git@github.com:you/repo.git
# ... repos persist across spot interruptions
```

---

## Advanced: Local Terraform

To manage the box from your laptop instead of GitHub Actions:

```bash
export TF_STATE_BUCKET=iac-dev-box-tfstate-YOUR_ID-us-west-2
export TF_STATE_KEY=iac-dev-box/us-west-2/terraform.tfstate
export TF_STATE_REGION=us-west-2
export TF_LOCK_TABLE=iac-dev-box-tf-locks-YOUR_ID-us-west-2

./scripts/tf_init.sh
terraform plan
terraform apply -auto-approve -var="enable_instance=true"
```

---

## Expanding storage

1. Increase `ebs_size_gb` in `terraform.tfvars`
2. `terraform apply`
3. SSH in and grow filesystem:
   ```bash
   sudo resize2fs /dev/xvdf
   ```

---

## Cost notes

- **Spot vs on-demand:** 60–70% cheaper; run `./scripts/prices.sh` for live estimates
- **96 GB EBS:** ~$10/month (charged even when compute is off; use `enable_instance=false` to pause just the compute)
- **Elastic IP:** Free while attached; $0.005/hr while unattached (we keep ours attached)
- **Auto-shutdown:** ~90 min idle → forces `enable_instance=false` to save money

---

## Security & MITM hardening

- **Host key persistence:** SSH host keys backed up to `/data` and restored on boot → stable identity across spot replacements
- **Strict host key checking:** `StrictHostKeyChecking accept-new` blocks unexpected key changes while allowing first-time connects
- **Secrets masking:** GitHub Actions logs mask environment variables to prevent accidental exposure
- **OIDC auth:** No long-lived AWS credentials in GitHub; OIDC federation only

See [SETUP_GUIDE.md](SETUP_GUIDE.md) and [GITHUB_SETUP_CHECKLIST.md](GITHUB_SETUP_CHECKLIST.md) for detailed walkthroughs.

---

## Troubleshooting

**"SSH fails with unknown key"**
→ Host key changed (spot replacement); delete old entry from `~/.ssh/known_hosts` and reconnect

**"Claude not in PATH"**
→ Use login shell: `ssh ec2-user@<host> 'bash -l -c claude'`

**"`sr` conda env not found"**
→ `source /data/miniforge3/etc/profile.d/conda.sh && conda activate sr`

**"Can't spot-interrupt detection active"**
→ Load avg > 0.2, docker containers running, or user sessions active = instance won't auto-shutdown

See [GITHUB_SETUP_CHECKLIST.md](GITHUB_SETUP_CHECKLIST.md) for comprehensive setup validation.

---

## License

MIT
