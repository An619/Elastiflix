output "bastion_ssm_command" {
  description = "Command to start an SSM session with the bastion host"
  value       = "aws ssm start-session --target ${module.bastion.instance_id} --region ${var.aws_region}"
}
