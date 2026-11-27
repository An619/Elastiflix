output "instance_id" {
  value = aws_instance.bastion.id
}

output "security_group_id" {
  description = "Security group of the SSM bastion, used to allow the bastion to reach the EKS control plane."
  value       = aws_security_group.bastion.id
}
