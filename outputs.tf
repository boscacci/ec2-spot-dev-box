output "instance_id" {
  description = "EC2 instance ID (from spot request)"
  value       = var.enable_instance ? aws_spot_instance_request.dev_box[0].spot_instance_id : ""
}

output "public_ip" {
  description = "Public IP of the dev box (SSH target)"
  value       = var.enable_eip ? aws_eip.dev_box[0].public_ip : (var.enable_instance ? aws_spot_instance_request.dev_box[0].public_ip : "")
}

output "ssh_host" {
  description = "Stable SSH hostname/IP to use (EIP if enabled, else instance public IP)"
  value       = var.enable_eip ? aws_eip.dev_box[0].public_ip : (var.enable_instance ? aws_spot_instance_request.dev_box[0].public_ip : "")
}

output "key_name" {
  description = "EC2 key pair name used for SSH"
  value       = var.key_name
}

output "ssh_command" {
  description = "SSH with agent forwarding (allows git to use your local keys)"
  value       = var.enable_eip ? "ssh -A -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_eip.dev_box[0].public_ip}" : (var.enable_instance ? "ssh -A -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_spot_instance_request.dev_box[0].public_ip}" : "")
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
  value       = var.enable_instance ? aws_spot_instance_request.dev_box[0].spot_price : ""
}
