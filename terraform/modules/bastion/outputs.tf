output "instance_id" {
  value = aws_instance.bastion.id
}

output "security_group_id" {
  description = "Security group used by the private SSM bastion"
  value       = aws_security_group.bastion.id
}
