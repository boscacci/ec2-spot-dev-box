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

# Default VPC — escape hatch: override with your own vpc/subnet if needed.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
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
  vpc_id      = data.aws_vpc.default.id

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
# Spot instance
# ---------------------------------------------------------------------------
resource "aws_spot_instance_request" "dev_box" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = local.selected.instance_type
  spot_price             = var.spot_max_price != "" ? var.spot_max_price : null
  wait_for_fulfillment   = true
  spot_type              = "one-time"
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.dev_box.id]
  subnet_id              = data.aws_subnets.default.ids[0]
  availability_zone      = var.availability_zone

  # The instance can see its own metadata (useful for scripts)
  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  root_block_device {
    volume_size = 30 # small root; real data lives on the persistent EBS
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/scripts/userdata.sh", {
    ebs_volume_id = aws_ebs_volume.data.id
    ebs_device    = "/dev/xvdf"
    mount_point   = "/data"
  })

  tags = {
    Name = var.instance_name
  }
}

# ---------------------------------------------------------------------------
# Attach persistent volume to the spot instance
# ---------------------------------------------------------------------------
resource "aws_volume_attachment" "data" {
  device_name  = "/dev/xvdf"
  volume_id    = aws_ebs_volume.data.id
  instance_id  = aws_spot_instance_request.dev_box.spot_instance_id
  force_detach = true # safe detach on destroy so the volume survives
}
