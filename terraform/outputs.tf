output "bastion_ssm_command" {
  description = "Command to start an SSM session with the bastion host"
  value       = "aws ssm start-session --target ${module.bastion.instance_id} --region ${var.aws_region}"
}

output "configure_kubectl" {
  description = "Command to configure kubectl to connect to the EKS cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
