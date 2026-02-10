# Quick Setup Guide - Dev Box with Phone Control

Set up a cloud dev box you can start/stop from your phone, with Claude, Jupyter, and SSH ready.

## Prerequisites

- AWS account with credentials configured (`aws configure`)
- GitHub repo (this one) and access to Settings
- Anthropic API key (for Claude on the box)
- EC2 key pair named `dev-box` in us-west-2 (create in EC2 → Key Pairs if needed)

## Step 1: Bootstrap (one time)

Creates S3 state bucket, DynamoDB lock table, and GitHub OIDC role.

```bash
cd bootstrap
terraform init
terraform apply
```

If you see **"Provider with url ... already exists"**, reuse the existing OIDC provider:

```bash
terraform apply -var='github_actions_oidc_provider_arn=arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com'
```

## Step 2: GitHub Actions (one time)

From the repo root, print the exact values to add:

```bash
./scripts/github_setup_from_bootstrap.sh
```

Then in GitHub: **Settings → Secrets and variables → Actions**

- **1 secret:** `AWS_ROLE_ARN` = (value from script)
- **3 variables:** `TF_STATE_BUCKET`, `TF_STATE_KEY`, `TF_LOCK_TABLE` = (values from script)

Region (`us-west-2`) and key name (`dev-box`) are hard-coded in the workflow; no need to set them in GitHub.

**Claude on the box:** create the secret in AWS once:

```bash
aws secretsmanager create-secret \
  --name CLAUDE_API_KEY \
  --secret-string "YOUR_ANTHROPIC_KEY" \
  --region us-west-2
```

## Step 3: Use from your phone

1. GitHub app → repo → **Actions** → **dev-box** → **Run workflow**
2. **action:** `start` | `destroy` | `plan`
3. **Instance size:** Large / Medium / High (or leave blank to keep current)
4. Run; wait ~2–3 min for start. SSH host is in the workflow output.

## Step 4: Connect

**From laptop:** use the EC2 key pair (e.g. `~/.ssh/dev-box.pem`):

```bash
# Get host (or use value from workflow output)
terraform -chdir=terraform output -raw ssh_host

ssh -i ~/.ssh/dev-box.pem ec2-user@<ip>
```

Optional (recommended once from WSL/laptop): seed your local bash dotfiles to persistent `/data/opt/rc` so aliases like `ll` survive respawns and work for phone logins too:

```bash
./scripts/seed_dotfiles_once.sh
```

**From phone:** same key; use Termux, JuiceSSH, etc. with the workflow output IP.

## Step 5: Verify on the box

```bash
# PATH and Claude
which claude && claude --version
# gt (gastown)
which gt && gt --version

# Conda and Jupyter
source /data/miniforge3/etc/profile.d/conda.sh
conda activate sr
jupyter --version
python -c "import pandas; print(pandas.__version__)"
```

Optional one-liner from the repo:

```bash
curl -fsSL https://raw.githubusercontent.com/boscacci/ec2-spot-dev-box/main/scripts/verify_setup.sh | bash
```

## What you get

- **Claude Code** – `claude` on PATH, API key from Secrets Manager
- **Jupyter + pandas** – `conda activate sr` then `jupyter lab`
- **gt / bd** – Gas Town and Beads on PATH
- **Persistent /data** – EBS survives instance stop/termination
- **Elastic IP** – Stable SSH host
- **Auto-shutdown** – ~90 min idle to save cost

## Workflow quick reference

| Action   | When to use        |
|----------|--------------------|
| `start`  | Launch instance    |
| `destroy`| Stop and keep EBS  |
| `plan`   | Preview changes    |

Sizes: **Large** (default), **Medium**, **High** – pick in the workflow dropdown.

## Troubleshooting

- **Missing AWS_ROLE_ARN / TF_*** – Run `./scripts/github_setup_from_bootstrap.sh` and add the printed secret + variables.
- **Claude not in PATH** – Use a login shell (`ssh ... bash -l -c 'claude --version'`) or `source /etc/profile.d/iac-dev-box.sh`.
- **`sr` env not found** – `source /data/miniforge3/etc/profile.d/conda.sh` then `conda activate sr`.

## GitHub Actions checklist

In GitHub: **Settings → Secrets and variables → Actions**

- **1 secret:** `AWS_ROLE_ARN` (bootstrap output `gha_terraform_role_arn`)
- **3 variables:** `TF_STATE_BUCKET`, `TF_STATE_KEY`, `TF_LOCK_TABLE` (bootstrap outputs)

Quick sanity checks:

```bash
cd bootstrap
terraform output
./scripts/test_workflow.sh
```

## Local Terraform (optional)

To run Terraform from your laptop instead of GitHub Actions:

```bash
export TF_STATE_BUCKET=... TF_STATE_KEY=... TF_STATE_REGION=us-west-2 TF_LOCK_TABLE=...
./scripts/tf_init.sh
terraform plan
terraform apply -auto-approve -var="enable_instance=true"
```

Use the same backend values from `./scripts/github_setup_from_bootstrap.sh`.
