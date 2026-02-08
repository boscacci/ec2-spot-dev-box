variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-west-2"
}

variable "availability_zone" {
  description = "AZ for the EBS volume and instance (must match)"
  type        = string
  default     = "us-west-2a"
}

# ---------------------------------------------------------------------------
# Flavor presets
# Pick one of: small, medium, large, xl
# Override spot_max_price if the default doesn't suit current spot market.
# ---------------------------------------------------------------------------
variable "flavor" {
  description = "Instance size preset: small | medium | large | xl"
  type        = string
  default     = "large"

  validation {
    condition     = contains(["small", "medium", "large", "xl"], var.flavor)
    error_message = "flavor must be one of: small, medium, large, xl"
  }
}

locals {
  flavors = {
    small  = { instance_type = "t3.large",   vcpu = 2, ram_gb = 8 }
    medium = { instance_type = "m7i.xlarge",  vcpu = 4, ram_gb = 16 }
    large  = { instance_type = "r7i.xlarge",  vcpu = 4, ram_gb = 32 }
    xl     = { instance_type = "r7i.2xlarge", vcpu = 8, ram_gb = 64 }
  }

  selected = local.flavors[var.flavor]
}

variable "spot_max_price" {
  description = "Max hourly bid for spot instance (empty = on-demand price cap)"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Persistent volume
# ---------------------------------------------------------------------------
variable "ebs_size_gb" {
  description = "Size of the persistent EBS data volume in GB"
  type        = number
  default     = 256
}

variable "ebs_volume_type" {
  description = "EBS volume type (gp3 is a good default)"
  type        = string
  default     = "gp3"
}

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------
variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH in (e.g. your home IP /32)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "instance_name" {
  description = "Name tag for the spot instance"
  type        = string
  default     = "dev-box"
}
