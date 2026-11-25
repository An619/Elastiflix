# IAM Role for AWS Load Balancer Controller (IRSA).
# ansible/playbook.yml installs the controller with
# serviceAccount.create=false, so the ServiceAccount + role must exist
# before Helm runs. The ServiceAccount itself is created by Ansible
# (kubectl) and annotated with this role's ARN.

module "alb_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-alb-role"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  # AWS-managed policy for the Load Balancer Controller.
  role_policy_arns = {
    policy = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
  }
}
