output "bastion_ssm_command" {
  description = "Command to start an SSM session with the bastion host"
  value       = "aws ssm start-session --target ${module.bastion.instance_id} --region ${var.aws_region}"
}

output "configure_kubectl" {
  description = "Command to configure kubectl to connect to the EKS cluster (run from the bastion when public access is disabled)"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "eks_cluster_name" {
  description = "EKS cluster name for downstream bootstrap tooling"
  value       = module.eks.cluster_name
}

output "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint; an empty list means public access is disabled and the SSM bastion is the only administrative path (module.eks v20.8.4 does not export the boolean, so this reports the input)."
  value       = var.cluster_endpoint_public_access_cidrs
}

output "alb_controller_role_arn" {
  description = "IRSA role ARN to annotate on the aws-load-balancer-controller ServiceAccount"
  value       = module.alb_irsa.iam_role_arn
}

output "eso_role_arn" {
  description = "IRSA role ARN for External Secrets Operator"
  value       = module.eso_irsa.iam_role_arn
}

output "ebs_csi_role_arn" {
  description = "IRSA role ARN for the EBS CSI driver"
  value       = module.ebs_csi_irsa.iam_role_arn
}
