# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

# Latest Amazon Linux 2023 AMI (arm64 would be cheaper, but x86 is more
# compatible with random dev tooling — swap to arm64 if you prefer Graviton)
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Networking
# Some AWS accounts do not have a "default VPC" (or any VPC at all).
# We therefore support:
# - explicit vpc_id/subnet_id overrides (escape hatch)
# - creating a minimal VPC + public subnet (create_vpc=true)
# - otherwise selecting the first VPC in-region and the first subnet in the chosen AZ
data "aws_vpcs" "available" {
  count = (var.create_vpc || var.vpc_id != "") ? 0 : 1
}

resource "aws_vpc" "dev_box" {
  count      = var.create_vpc ? 1 : 0
  cidr_block = var.vpc_cidr

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.instance_name}-vpc"
  }
}

resource "aws_internet_gateway" "dev_box" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.dev_box[0].id

  tags = {
    Name = "${var.instance_name}-igw"
  }
}

resource "aws_subnet" "public" {
  count                   = var.create_vpc ? 1 : 0
  vpc_id                  = aws_vpc.dev_box[0].id
  availability_zone       = var.availability_zone
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.instance_name}-public-subnet"
  }
}

resource "aws_route_table" "public" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.dev_box[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dev_box[0].id
  }

  tags = {
    Name = "${var.instance_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = var.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

locals {
  discovered_vpc_id = (var.create_vpc || var.vpc_id != "") ? "" : try(data.aws_vpcs.available[0].ids[0], "")
  selected_vpc_id   = var.create_vpc ? aws_vpc.dev_box[0].id : (var.vpc_id != "" ? var.vpc_id : local.discovered_vpc_id)
}

data "aws_caller_identity" "current" {}

data "aws_subnets" "selected" {
  count = var.create_vpc ? 0 : 1

  filter {
    name   = "vpc-id"
    values = [local.selected_vpc_id]
  }

  filter {
    name   = "availability-zone"
    values = [var.availability_zone]
  }
}

# ---------------------------------------------------------------------------
# Persistent EBS volume
# This volume survives spot terminations. It gets mounted by userdata on boot.
# ---------------------------------------------------------------------------
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.ebs_size_gb
  type              = var.ebs_volume_type

  tags = {
    Name = "${var.instance_name}-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Security group — SSH only by default
# ---------------------------------------------------------------------------
resource "aws_security_group" "dev_box" {
  name_prefix = "${var.instance_name}-"
  description = "SSH access for dev box"
  vpc_id      = local.selected_vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

# ---------------------------------------------------------------------------
# Key pair (optional, managed by Terraform)
# ---------------------------------------------------------------------------
resource "aws_key_pair" "dev_box" {
  count = var.ssh_public_key_path != "" ? 1 : 0

  key_name   = var.key_name
  public_key = file(var.ssh_public_key_path)

  tags = {
    Name = "${var.instance_name}-key"
  }
}

# ---------------------------------------------------------------------------
# IAM: instance role (Secrets Manager + optional EIP association)
# ---------------------------------------------------------------------------
locals {
  enable_instance_role = var.enable_claude_api_key_from_secrets_manager || var.enable_eip
  claude_secret_arn    = startswith(var.claude_api_key_secret_id, "arn:") ? var.claude_api_key_secret_id : "arn:aws:secretsmanager:${var.claude_secret_region}:${data.aws_caller_identity.current.account_id}:secret:${var.claude_api_key_secret_id}*"

  # Build IAM statements as a heterogenous tuple (jsonencode-friendly) and then filter nulls.
  iam_statements = [
    for s in concat(
      var.enable_claude_api_key_from_secrets_manager ? [
        {
          Sid    = "ReadClaudeApiKeySecret"
          Effect = "Allow"
          Action = [
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret"
          ]
          Resource = local.claude_secret_arn
        },
        # If the secret uses a customer-managed KMS key, this is required.
        # Scoped via Secrets Manager service + caller account.
        {
          Sid      = "KmsDecryptForSecretsManager"
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = "*"
          Condition = {
            StringEquals = {
              "kms:ViaService"    = "secretsmanager.${var.claude_secret_region}.amazonaws.com"
              "kms:CallerAccount" = data.aws_caller_identity.current.account_id
            }
          }
        }
      ] : [null, null],
      var.enable_eip ? [
        {
          Sid    = "AssociateDevBoxEip"
          Effect = "Allow"
          Action = [
            "ec2:AssociateAddress",
            "ec2:DescribeAddresses",
            "ec2:DescribeInstances"
          ]
          Resource = "*"
        }
      ] : [null]
    ) : s if s != null
  ]
}

resource "aws_iam_role" "dev_box" {
  count = local.enable_instance_role ? 1 : 0

  name_prefix = "${var.instance_name}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.instance_name}-role"
  }
}

resource "aws_iam_role_policy" "dev_box_secrets" {
  count = local.enable_instance_role ? 1 : 0

  name_prefix = "${var.instance_name}-secrets-"
  role        = aws_iam_role.dev_box[0].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.iam_statements
  })
}

resource "aws_iam_instance_profile" "dev_box" {
  count = local.enable_instance_role ? 1 : 0

  name_prefix = "${var.instance_name}-"
  role        = aws_iam_role.dev_box[0].name
}

# ---------------------------------------------------------------------------
# Elastic IP (stable SSH endpoint)
# Associated by userdata on boot (works across spot interruptions).
# ---------------------------------------------------------------------------
resource "aws_eip" "dev_box" {
  count  = var.enable_eip ? 1 : 0
  domain = "vpc"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${var.instance_name}-eip"
  }
}

# ---------------------------------------------------------------------------
# Spot instance (managed as aws_instance so "destroy" actually terminates compute)
# ---------------------------------------------------------------------------
resource "aws_instance" "dev_box" {
  count = var.enable_instance ? 1 : 0

  ami           = data.aws_ami.al2023.id
  instance_type = local.selected.instance_type

  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type             = "one-time"
      max_price                      = var.spot_max_price != "" ? var.spot_max_price : null
      instance_interruption_behavior = "terminate"
    }
  }

  key_name                    = var.ssh_public_key_path != "" ? aws_key_pair.dev_box[0].key_name : var.key_name
  vpc_security_group_ids      = [aws_security_group.dev_box.id]
  subnet_id                   = var.create_vpc ? aws_subnet.public[0].id : (var.subnet_id != "" ? var.subnet_id : data.aws_subnets.selected[0].ids[0])
  availability_zone           = var.availability_zone
  iam_instance_profile        = local.enable_instance_role ? aws_iam_instance_profile.dev_box[0].name : null
  associate_public_ip_address = true

  # The instance can see its own metadata (useful for scripts)
  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_size = 30 # small root; real data lives on the persistent EBS
    volume_type = "gp3"
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/scripts/userdata.sh", {
    ebs_volume_id            = aws_ebs_volume.data.id
    ebs_device               = "/dev/xvdf"
    mount_point              = "/data"
    aws_region               = var.aws_region
    enable_claude_secret     = var.enable_claude_api_key_from_secrets_manager
    claude_api_key_secret_id = var.claude_api_key_secret_id
    claude_secret_region     = var.claude_secret_region
    enable_eip               = var.enable_eip
    eip_allocation_id        = var.enable_eip ? aws_eip.dev_box[0].id : ""
    additional_ssh_keys      = join("\n", var.additional_ssh_public_keys)
  }))

  tags = {
    Name = var.instance_name
  }
}

# ---------------------------------------------------------------------------
# Attach persistent volume to the spot instance
# ---------------------------------------------------------------------------
resource "aws_volume_attachment" "data" {
  count = var.enable_instance ? 1 : 0

  device_name  = "/dev/xvdf"
  volume_id    = aws_ebs_volume.data.id
  instance_id  = aws_instance.dev_box[0].id
  force_detach = true # safe detach on destroy so the volume survives
}
