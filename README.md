# iac-dev-box

Terraform config for spinning up EC2 spot instances as disposable dev boxes. Comes pre-loaded with Docker, Claude Code, Gastown, your dotfiles, and a persistent EBS volume that survives spot terminations.

## Flavors

| Name   | Instance Type  | vCPU | RAM   | Use case         |
|--------|---------------|------|-------|------------------|
| small  | t3.large      | 2    | 8 GB  | Cheap dev        |
| medium | m7i.xlarge    | 4    | 16 GB | General purpose  |
| large  | r7i.xlarge    | 4    | 32 GB | Memory heavy     |
| xl     | r7i.2xlarge   | 8    | 64 GB | The big one      |

## What you get

- **Spot instance**: ephemeral, cheap, disposable
- **Persistent 96 GB gp3 EBS volume**: mounts to `/data`, formatted on first use, survives spot terminations
- **Amazon Linux 2023**: lightweight, `dnf`, SSM agent baked in
- **Docker**: enabled and running, `ec2-user` in the docker group
- **Claude Code**: installed via the official installer
- **Gas Town (gt) + beads (bd)**: installed from source; persistent workspace at `~/gt` (backed by `/data/gt`)
- **Your dotfiles**: cloned from `boscacci/rc` — `.bashrc`, `.bash_aliases`, `.bash_profile`, `.vimrc` + Vundle plugins
- **Miniforge (conda)**: installed to `/data/miniforge3` so environments persist across spot terminations
- **nvm + Node LTS**: for JS/TS tooling
- **SSH agent forwarding**: your local SSH keys are forwarded to the box so it can interact with your GitHub/GitLab repos — no private keys ever touch the instance
- **Claude auth from Secrets Manager**: reads the `CLAUDE_API_KEY` secret (configurable) and exports `ANTHROPIC_API_KEY` automatically on login
- **SSH-only security group**: locked to your CIDR

## Prerequisites

- Terraform >= 1.5
- An AWS account with credentials configured (`aws configure` or env vars)
- An existing EC2 key pair in your target region
- Your SSH keys loaded in your local ssh-agent (`ssh-add`)
- An AWS Secrets Manager secret containing your Anthropic API key (defaults to secret id `CLAUDE_API_KEY`)

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set key_name and allowed_ssh_cidrs

terraform init
terraform plan
terraform apply
```

### Connect

The fastest way in:

```bash
./scripts/connect.sh
```

Or manually with agent forwarding (`-A` is the critical flag):

```bash
ssh -A -i ~/.ssh/my-key-pair.pem ec2-user@<public_ip>
```

You can also drop the snippet from `ssh-config.example` into your `~/.ssh/config` and then just:

```bash
ssh dev-box
```

### SSH agent forwarding (how repo access works)

Your local machine's ssh-agent holds your private keys. When you connect with `ssh -A` (or `ForwardAgent yes` in config), the remote box can use those keys for git operations without the keys ever being copied to the instance.

This means the dev box can clone your private repos, push to GitHub, interact with GitLab — all using whatever keys you have loaded locally. Run `ssh-add -l` on both your local machine and the dev box to verify forwarding is working.

### Claude Code / Gastown auth (Secrets Manager)

By default, the instance attaches an IAM role that can read one Secrets Manager secret (name/ARN set by `claude_api_key_secret_id`) and exports it on login as:

- `ANTHROPIC_API_KEY` (what most tooling expects)
- `CLAUDE_API_KEY` (alias)

Disable this behavior with `enable_claude_api_key_from_secrets_manager = false`.

### Tear down

```bash
terraform destroy
# The persistent EBS volume has prevent_destroy — Terraform will error.
# This is intentional. Remove the lifecycle block if you truly want to delete it.
```

## Persistent volume

The EBS volume is created once and reattached on every `terraform apply`. Your data in `/data` survives instance terminations. Miniforge installs to `/data/miniforge3` so your conda envs persist too.

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

To destroy the volume (data loss), temporarily remove `prevent_destroy` from `main.tf` and run `terraform destroy`.

## What the userdata installs

| Layer | What | Where |
|-------|------|-------|
| System | git, tmux, htop, jq, gcc, make, vim | dnf |
| Docker | docker CE | systemd, ec2-user in docker group |
| Node | nvm + Node LTS | `~/.nvm` |
| Claude Code | `claude` CLI | official installer |
| Gas Town | `gt` + `bd` | `~/go/bin` + persistent workspace at `~/gt` |
| Conda | Miniforge | `/data/miniforge3` (persistent) |
| Dotfiles | `boscacci/rc` | `~/.rc`, symlinked to `~/` |

## Cost notes

Spot instances are significantly cheaper than on-demand (often 60-90% off). The EBS volume costs ~$0.08/GB/month for gp3, so 96 GB ≈ $7.50/month whether the instance is running or not. Remember to `terraform destroy` the instance when you're done for the day.
