# IAM Role for AWS Load Balancer Controller (IRSA).
# The chart is pinned to v3.7.0 in Ansible. Keep this IAM policy sourced from
# the same upstream release and review it whenever the controller is upgraded.
# ansible/playbook.yml creates the ServiceAccount and annotates it with this
# Terraform role ARN before installing the controller.

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.cluster_name}-alb-controller-policy"
  description = "Upstream AWS Load Balancer Controller v3.7.0 policy"
  policy      = file("${path.module}/policies/aws-load-balancer-controller-v3.7.0.json")
}

module "alb_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name = "${var.cluster_name}-alb-role"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  role_policy_arns = {
    policy = aws_iam_policy.alb_controller.arn
  }
}
