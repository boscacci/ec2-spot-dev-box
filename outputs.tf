output "instance_id" {
  description = "EC2 instance ID (from spot request)"
  value       = aws_spot_instance_request.dev_box.spot_instance_id
}

output "public_ip" {
  description = "Public IP of the dev box (SSH target)"
  value       = aws_spot_instance_request.dev_box.public_ip
}

output "ssh_command" {
  description = "SSH with agent forwarding (allows git to use your local keys)"
  value       = "ssh -A -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_spot_instance_request.dev_box.public_ip}"
}

output "flavor" {
  description = "Instance flavor that was launched"
  value       = "${var.flavor} (${local.selected.instance_type}: ${local.selected.vcpu} vCPU, ${local.selected.ram_gb} GB RAM)"
}

output "ebs_volume_id" {
  description = "Persistent EBS volume ID (survives instance termination)"
  value       = aws_ebs_volume.data.id
}

output "spot_price" {
  description = "Spot bid price (empty = up to on-demand)"
  value       = aws_spot_instance_request.dev_box.spot_price
}
