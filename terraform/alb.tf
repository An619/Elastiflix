# IAM Role for AWS Load Balancer Controller (IRSA).
# ansible/playbook.yml installs the controller with
# serviceAccount.create=false, so the ServiceAccount + role must exist
# before Helm runs. The ServiceAccount itself is created by Ansible
# (kubectl) and annotated with this role's ARN.
#
# The policy below is the upstream controller policy for the chart version
# pinned in ansible/playbook.yml (v2.7.2), vendored so the permission set is
# reviewable in a diff. It replaces the AWS-managed
# ElasticLoadBalancingFullAccess policy, which also grants permissions the
# controller never uses (for example unrestricted ELB management outside the
# cluster's own tag scope).

locals {
  alb_controller_policy_path = "${path.module}/policies/aws-load-balancer-controller-v2.7.2.json"
}

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.cluster_name}-alb-controller-policy"
  description = "Upstream AWS Load Balancer Controller v2.7.2 policy (scoped replacement for ElasticLoadBalancingFullAccess)"
  policy      = file(local.alb_controller_policy_path)

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

module "alb_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0" # pinned; was "~> 5.0"

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
