# ec2-dev-box

Terraform config for spinning up EC2 spot instances as ephemeral dev boxes with a **persistent EBS volume** that survives terminations.

## Flavors

| Name   | Instance Type  | vCPU | RAM   | Use case         |
|--------|---------------|------|-------|------------------|
| small  | t3.large      | 2    | 8 GB  | Cheap dev        |
| medium | m7i.xlarge    | 4    | 16 GB | General purpose  |
| large  | r7i.xlarge    | 4    | 32 GB | Memory heavy     |
| xl     | r7i.2xlarge   | 8    | 64 GB | The big one      |

## What you get

- **Spot instance**: ephemeral, cheap, disposable
- **Persistent 256 GB gp3 EBS volume**: mounts to `/data`, formatted on first use, survives spot terminations
- **Amazon Linux 2023**: lighter than Ubuntu, `dnf`, SSM agent baked in
- **Userdata installs**: git, docker, tmux, htop, nvm/node, miniforge (conda — installed to `/data` so it persists)
- **SSH-only security group**: locked to your CIDR

## Prerequisites

- Terraform >= 1.5
- An AWS account with credentials configured (`aws configure` or env vars)
- An existing EC2 key pair in your target region

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set key_name and allowed_ssh_cidrs

terraform init
terraform plan
terraform apply
```

SSH in:

```bash
# Terraform prints this for you
ssh -i ~/.ssh/my-key-pair.pem ec2-user@<public_ip>
```

Tear down the instance (keeps the EBS volume):

```bash
terraform destroy
# The persistent EBS volume has prevent_destroy — Terraform will error.
# This is intentional. Remove the lifecycle block if you truly want to delete it.
```

## Persistent volume

The EBS volume is created once and reattached on every `terraform apply`. Your data in `/data` survives instance terminations. Miniforge installs to `/data/miniforge3` so your conda envs persist too.

To destroy the volume (data loss), temporarily remove `prevent_destroy` from `main.tf` and run `terraform destroy`.

## Cost notes

Spot instances are significantly cheaper than on-demand (often 60-90% off). The EBS volume costs ~$0.08/GB/month for gp3, so 256 GB = ~$20/month whether the instance is running or not. Remember to `terraform destroy` the instance when you're done for the day.
