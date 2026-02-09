# Quick Setup Guide - Dev Box with Phone Control

This guide helps you set up a cloud dev box that you can start/stop from your phone with Claude, Jupyter, and your SSH keys ready to go.

## Prerequisites

1. AWS account with credentials configured
2. GitHub account with repository access
3. Anthropic API key

## Step 1: Bootstrap (One-Time Setup)

Run the bootstrap to create the S3 backend and GitHub Actions OIDC role:

```bash
cd bootstrap
terraform init
terraform apply
```

**Save these outputs** - you'll need them for GitHub:
- `tf_state_bucket`
- `tf_lock_table`
- `tf_state_key`
- `gha_terraform_role_arn`

## Step 2: Configure GitHub Secrets and Variables

Go to your repo: **Settings → Secrets and variables → Actions**

### Required Variables (Repository or Environment level)

**AWS Authentication:**
- `AWS_ROLE_ARN` = (value from `gha_terraform_role_arn`)

**Terraform Backend:**
- `TF_STATE_BUCKET` = (value from `tf_state_bucket`)
- `TF_LOCK_TABLE` = (value from `tf_lock_table`)
- `TF_STATE_KEY` = (value from `tf_state_key`)
- `TF_STATE_REGION` = `us-west-2` (or your region)

**Dev Box Settings:**
- `DEVBOX_KEY_NAME` = name of your EC2 key pair (e.g., `dev-box`)
- `DEVBOX_AWS_REGION` = `us-west-2` (or your region)
- `DEVBOX_CREATE_VPC` = `false` (set to `true` if you need a new VPC)

### Required Secrets

**SSH Keys (for syncing your local keys):**
- `DEVBOX_ADDITIONAL_SSH_KEYS` = Paste the contents of your SSH public keys (one per line)
  ```bash
  # Get your public keys:
  cat ~/.ssh/id_rsa.pub
  cat ~/.ssh/dev-box.pem.pub
  
  # Copy the output and paste into the secret
  # Example format:
  # ssh-rsa AAAAB3Nza... user@host
  # ssh-rsa AAAAB3Nza... user@otherhost
  ```

**Claude API Key:**
First, store your Anthropic API key in AWS Secrets Manager:
```bash
aws secretsmanager create-secret \
  --name CLAUDE_API_KEY \
  --secret-string "YOUR_ANTHROPIC_KEY..." \
  --region us-west-2
```

Then set these variables:
- `DEVBOX_CLAUDE_SECRET_ID` = `CLAUDE_API_KEY`
- `DEVBOX_CLAUDE_SECRET_REGION` = `us-west-2` (or where you stored it)

## Step 3: Using the Dev Box from Your Phone

1. Open GitHub mobile app
2. Go to your repository
3. Navigate to **Actions → dev-box → Run workflow**
4. Select options:
   - **action**: `start` (to launch) or `stop` (to terminate)
   - **flavor**: 
     - `L` = Large (4 vCPU, 32 GB RAM) - default, good for most work
     - `M` = Medium (4 vCPU, 16 GB RAM) - lighter workloads
     - `H` = High (8 vCPU, 64 GB RAM) - heavy workloads
     - `XL` = Extra Large (8 vCPU, 64 GB RAM) - same as H
     - _(leave blank to keep current size)_

## Step 4: Connecting to Your Dev Box

### From your laptop (VSCode/Cursor):

```bash
# Update your SSH config and connect
./scripts/connect.sh
```

Or manually:
```bash
# Get the IP address
terraform output -raw ssh_host

# SSH in
ssh ec2-user@<ip-address>
```

### From your phone (Termux, JuiceSSH, etc.):

Get the IP from the GitHub Actions output or Terraform output, then:
```
ssh ec2-user@<ip-address>
```

Your SSH keys from `DEVBOX_ADDITIONAL_SSH_KEYS` are automatically added!

## Step 5: Verify Everything Works

Once connected, run this verification script:

```bash
# Check Claude is authenticated
echo $ANTHROPIC_API_KEY | head -c 10
# Should show: YOUR_ANTHROPIC_KEY

# Check conda 'sr' environment exists
conda env list | grep sr
# Should show: sr  /data/miniforge3/envs/sr

# Activate and check Jupyter
conda activate sr
jupyter --version
# Should show version numbers

# Check pandas
python -c "import pandas; print(pandas.__version__)"
# Should show pandas version

# Check your SSH keys
cat ~/.ssh/authorized_keys | wc -l
# Should show at least 2 keys (the EC2 key + your synced keys)

# Check persistent storage
df -h /data
# Should show your EBS volume mounted
```

## What You Get

✅ **Claude Code authenticated and ready** - `claude` command available, API key auto-loaded  
✅ **Your SSH keys synced** - Same keys as your WSL2/laptop  
✅ **Jupyter ready** - `conda activate sr` then `jupyter lab`  
✅ **Pandas and data science tools** - numpy, matplotlib, seaborn, scikit-learn  
✅ **Persistent storage** - Everything in `/data` survives spot interruptions  
✅ **Gas Town + Beads** - `gt` and `bd` commands available  
✅ **Docker ready** - `docker` command available  
✅ **Auto-shutdown** - Stops after 90 minutes of idle time to save money

## Workflow Quick Reference

### L/M/H Size Guide
- **M** (Medium): t3.large equivalent, ~$0.08/hr spot - Light development
- **L** (Large): r7i.xlarge, ~$0.15/hr spot - Normal development (default)
- **H** (High): r7i.2xlarge, ~$0.30/hr spot - Heavy data work

### Common Actions

**Start dev box (large):**
- Actions → dev-box → Run workflow
- action: `start`, flavor: `L`

**Start dev box (high power):**
- Actions → dev-box → Run workflow
- action: `start`, flavor: `H`

**Stop to save money:**
- Actions → dev-box → Run workflow
- action: `stop`

**Check what you'll spend (plan):**
- Actions → dev-box → Run workflow
- action: `plan`, flavor: `L`

## Cost Savings

The dev box auto-terminates after 90 minutes of idle time. This means:
- You only pay for what you use
- No accidental overnight runs
- Persistent `/data` volume keeps your work safe

**Typical costs (spot pricing):**
- Large (L): ~$0.15/hour = $1.20 for 8 hours
- High (H): ~$0.30/hour = $2.40 for 8 hours
- Plus ~$10/month for 96GB EBS storage (always on)

## Troubleshooting

### "Claude not authenticated"
```bash
# Manually refresh the API key
claude_key_refresh
echo $ANTHROPIC_API_KEY
```

### "sr environment not found"
```bash
# Recreate it
source /data/miniforge3/etc/profile.d/conda.sh
conda create -y -n sr python=3.11 jupyter jupyterlab pandas numpy matplotlib seaborn scikit-learn
```

### "SSH keys not synced"
Check that `DEVBOX_ADDITIONAL_SSH_KEYS` is set in GitHub Secrets with your public keys (not private keys!).

### "Can't connect from phone"
1. Get the IP: Check GitHub Actions output or run locally: `terraform output -raw ssh_host`
2. Verify security group allows your IP (default is 0.0.0.0/0 which allows all)
3. Make sure the instance is running: `terraform output` should show resources

## Next Steps

1. Clone your repos to `/data/repos` (they'll survive spot terminations)
2. Set up your dotfiles in `/data/opt/rc`
3. Install additional conda packages in the `sr` environment
4. Configure Gas Town workflows with `gt`

## Advanced: Local Management

You can also manage the dev box from your laptop:

```bash
# Initialize local Terraform
./scripts/tf_init.sh

# Plan changes
./scripts/plan.sh

# Apply (start)
./scripts/apply.sh

# Stop
terraform apply -auto-approve -var="enable_instance=false"
```
