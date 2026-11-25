# NOTE: The EKS cluster itself is defined in main.tf (module "eks").
# This file only holds the ESO IRSA role. Do NOT declare a second
# module "eks" here — Terraform fails with "Duplicate module call".

data "aws_caller_identity" "current" {}

# IAM Role for External Secrets Operator (ESO)
module "eso_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-eso-role"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "aws_iam_policy" "eso_policy" {
  name = "${var.cluster_name}-eso-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:elastiflix/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eso_attach" {
  role       = module.eso_irsa.iam_role_name
  policy_arn = aws_iam_policy.eso_policy.arn
}
