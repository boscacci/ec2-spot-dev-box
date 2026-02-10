# iac-dev-box

Terraform config for spinning up EC2 spot instances as disposable dev boxes, with a persistent `/data` EBS volume and a stable SSH endpoint (Elastic IP).

## 🚀 Quick Start

**New here?** See the [**SETUP_GUIDE.md**](SETUP_GUIDE.md) for minimal setup. After bootstrap, run `./scripts/github_setup_from_bootstrap.sh` to print the exact GitHub secret and variables to add (1 secret + 3 variables).

**Key features:**
- 📱 Start/stop from your phone via GitHub Actions with simple L/M/H/XL size options
- 🔑 Your SSH keys automatically synced from WSL2/laptop to the instance
- 🤖 Claude authenticated and ready to use on launch
- 📊 Jupyter + pandas + data science stack in `sr` conda environment
- 💾 Persistent `/data` volume survives spot interruptions
- 💰 Auto-shutdown after 90 minutes to save money

## Flavors

| Name   | Instance Type  | vCPU | RAM   | Use case         |
|--------|---------------|------|-------|------------------|
| small  | t3.large      | 2    | 8 GB  | Cheap dev        |
| medium | m7i.xlarge    | 4    | 16 GB | General purpose  |
| large  | r7i.xlarge    | 4    | 32 GB | Memory heavy     |
| xl     | r7i.2xlarge   | 8    | 64 GB | The big one      |

## What you get (high level)

- **Spot instance** (ephemeral) + **persistent `/data` EBS** (survives interruptions/terminations)
- **Elastic IP** (stable endpoint for your phone) and auto-association on boot
- **Fast boots**: heavy tooling cached onto `/data` and guarded by `/data/.iac-dev-box/bootstrap-v1`
- **Tools**: Docker, Claude Code, `gt`/`bd`, Miniforge, Node (nvm), Vim + Vundle plugins
- **Auto-terminate**: shuts down after ~90 minutes of “idle”
- **Pricing visibility**: `scripts/prices.sh` shows spot vs on-demand + savings estimates (on-demand lookup needs `pricing:GetProducts`)

## Prerequisites

- Terraform >= 1.5
- An AWS account with credentials configured (`aws configure` or env vars)
- SSH keypair for instance access
  - Recommended: generate a local key and let Terraform create the EC2 Key Pair from your public key (`ssh_public_key_path`).
  - Alternative: set `ssh_public_key_path = ""` and use an existing EC2 Key Pair (`key_name`) in-region.
- Your SSH keys loaded in your local ssh-agent (`ssh-add`)
- (Optional) An AWS Secrets Manager secret containing your Anthropic API key (defaults to secret id `CLAUDE_API_KEY`)
  - If your secret is in a different region than the instance, set `claude_secret_region` (e.g. `us-east-2`).
  - To skip Secrets Manager entirely, set `enable_claude_api_key_from_secrets_manager = false`.

If your AWS account has **no default VPC**, set `create_vpc = true` in `terraform.tfvars`.

## Helper Scripts

**Print GitHub setup (after bootstrap):**
```bash
./scripts/github_setup_from_bootstrap.sh
```
Outputs the exact secret and three variables to add in Settings → Secrets and variables → Actions.

**Verify setup on the instance:**
```bash
# SSH into the dev box, then run:
./scripts/verify_setup.sh
```
Or download and run directly:
```bash
curl -fsSL https://raw.githubusercontent.com/boscacci/iac-dev-box/main/scripts/verify_setup.sh | bash
```

## One-time local setup (recommended even if you use GitHub Actions)

### 1) Create `terraform.tfvars`

```bash
cp terraform.tfvars.example terraform.tfvars
```

At minimum, set:
- `key_name`
- `ssh_public_key_path` (recommended) and ensure you have the matching private key locally
- `allowed_ssh_cidrs` (consider restricting to your IP /32)

### 2) Make `ssh dev-box` work

The connect script updates `~/.ssh/config` directly with the current dev-box IP. If you don't already have a `Host dev-box` entry, it will be added automatically on first connect.

## Option A (recommended): phone start/stop via GitHub Actions

This is the “power button from my phone” setup. Terraform runs in GitHub Actions using **OIDC** (no long-lived AWS keys), with remote state in **S3** + locking in **DynamoDB**.

### 1) One-time bootstrap

This creates:
- S3 state bucket (versioned, encrypted)
- DynamoDB lock table
- GitHub OIDC IAM role (restricted to `boscacci/iac-dev-box` on branch `main`)

```bash
cd bootstrap
terraform init
terraform apply
```

If you hit this error:

> `EntityAlreadyExists: Provider with url https://token.actions.githubusercontent.com already exists`

…your AWS account already has the GitHub Actions OIDC provider. In that case:

- In AWS Console, go to **IAM → Identity providers**
- Click the one with URL `token.actions.githubusercontent.com`
- Copy its **ARN**
- Re-run bootstrap with:

```bash
terraform apply -var='github_actions_oidc_provider_arn=arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com'
```

If you’re using **GitHub Environment** secrets/vars (the workflow input `environment`, default `dev-box`), bootstrap also needs to allow that Environment in the role trust policy (defaults to `dev-box` here). To override:

```bash
terraform apply -var='github_environment=dev-box'
```

Outputs you’ll use:
- `tf_state_bucket`
- `tf_lock_table`
- `tf_state_key`
- `gha_terraform_role_arn`

### 2) Configure the repo (GitHub Settings → Secrets and variables → Actions)

**Simplest:** from repo root run `./scripts/github_setup_from_bootstrap.sh` and add what it prints.

- **1 secret:** `AWS_ROLE_ARN` = bootstrap output `gha_terraform_role_arn`
- **3 variables:** `TF_STATE_BUCKET`, `TF_STATE_KEY`, `TF_LOCK_TABLE` = bootstrap outputs

Region (`us-west-2`) and key name (`dev-box`) are fixed in the workflow. You need an EC2 key pair named `dev-box` in the region and (optionally) a Secrets Manager secret `CLAUDE_API_KEY` for Claude on the box. See [SETUP_GUIDE.md](SETUP_GUIDE.md) and [GITHUB_SETUP_CHECKLIST.md](GITHUB_SETUP_CHECKLIST.md).

### 3) Start/stop from your phone

In GitHub mobile: **Actions → dev-box → Run workflow**. Choose **action** (`start` / `destroy` / `plan`) and **Instance size** (Large / Medium / High or leave blank).

### Phone workflow quick reference

**Actions:**
- `start` - Launch the instance (default)
- `destroy` - Terminate the instance (EIP, EBS, and all data are preserved)
- `plan` - Preview changes without applying

**Instance sizes:**
- **Large**: 4 vCPU, 32 GB RAM (~$0.15/hr) - Default, good for most work
- **Medium**: 4 vCPU, 16 GB RAM (~$0.08/hr) - Lighter workloads
- **High**: 8 vCPU, 64 GB RAM (~$0.30/hr) - Heavy data work
- Leave blank to keep current size

## Local usage (after Option A bootstrap)

Set backend env vars (same values as above), then:

```bash
./scripts/tf_init.sh
./scripts/plan.sh
./scripts/apply.sh
```

If `./scripts/tf_init.sh` fails with a message about **state migration approval** (because you previously had local state or changed backend settings), re-run once with:

```bash
TF_INIT_FORCE_COPY=1 ./scripts/tf_init.sh
```

### Stop without destroying persistent resources

```bash
terraform apply -auto-approve -var="enable_instance=false"
```

### Pricing (spot vs on-demand + savings)

```bash
./scripts/prices.sh
```

### Connect

The fastest way in:

```bash
./scripts/connect.sh
```

This updates the `Host dev-box` entry in `~/.ssh/config` with the current IP, then connects. Host key checking is enabled (`StrictHostKeyChecking accept-new`), and host keys are persisted on `/data` so subsequent spot replacements keep the same trusted key.

### Phone access (Android ConnectBot)

Host string (exact format):
- `ec2-user@<ssh_host>:22`
  - `<ssh_host>`: `terraform output -raw ssh_host`

ConnectBot settings:
- **Encoding**: `UTF-8`
- **Close on disconnect**: `Yes`

## Bootstrapping behavior (fast reboots / spot replacements)

Marker: `/data/.iac-dev-box/bootstrap-v1`

```bash
sudo touch /data/.iac-dev-box/force-bootstrap
```

## Persistent git repos on `/data`

Your git credentials **never touch the instance**. Instead, SSH agent forwarding (`ssh -A`) makes your local keys available to git on the box.

Once SSH'd in:

```bash
mkdir -p /data/repos
cd /data/repos

# Clone your repos (they'll survive spot terminations)
git clone git@github.com:boscacci/iac-dev-box.git
git clone git@github.com:boscacci/genetics-map-app.git
git clone git@github.com:boscacci/robertboscacci.com.git
# ... etc

# Optional: symlink ~/repos -> /data/repos for convenience
ln -s /data/repos ~/repos
```

For **Azure DevOps** repos (like your `silverride/*` repos), SSH works the same way via agent forwarding:

```bash
git clone git@ssh.dev.azure.com:v3/SilverRide/Database%20Components/CPUC-Reports
```

## Expanding the EBS volume later

1. Increase `ebs_size_gb` in `terraform.tfvars`.
2. Apply:

```bash
terraform apply
```

3. On the instance, grow the filesystem (device is unpartitioned in this setup):

```bash
sudo resize2fs /dev/xvdf
```

## Destructive operations (EIP/EBS)

- EBS volume and Elastic IP are protected with `prevent_destroy`.
- If you truly want to delete them, temporarily remove the lifecycle blocks in `main.tf`, then run `terraform destroy`.

## Cost notes

Spot is typically much cheaper than on-demand; `./scripts/prices.sh` shows estimated savings. The persistent 96GB gp3 EBS volume costs money even when the instance is stopped. Use `enable_instance=false` to stop compute while keeping data + endpoint.
