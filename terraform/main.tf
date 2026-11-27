# terraform/main.tf

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1" # Pinned version (Fixes Checkov CKV_TF_1)

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  # Required for the AWS load balancer controller to discover subnets, and for
  # cost allocation reporting (Phase 7).
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                = "1"
    "kubernetes.io/cluster/${var.cluster_name}-eks"  = "shared"
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb"                         = "1"
    "kubernetes.io/cluster/${var.cluster_name}-eks"  = "shared"
  }

  enable_nat_gateway = true
  single_nat_gateway = var.environment != "production"
  enable_vpn_gateway = false

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = var.cluster_name
    ManagedBy   = "terraform"
  }
}

module "bastion" {
  source = "./modules/bastion"

  vpc_id       = module.vpc.vpc_id
  # Private subnet: SSM reaches AWS APIs via the NAT gateway - the
  # bastion never needs a public IP (satisfies Checkov CKV_AWS_88).
  subnet_id    = module.vpc.private_subnets[0]
  cluster_name = var.cluster_name
  environment  = var.environment
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.4" # Pinned version

  cluster_name    = "${var.cluster_name}-eks"
  cluster_version = var.cluster_version

  # Networking: the API endpoint is private by default and reachable through
  # the SSM bastion. Public access is opt-in and must be CIDR-restricted; a
  # world-open control plane endpoint is not a default this repository accepts.
  vpc_id                               = module.vpc.vpc_id
  subnet_ids                           = module.vpc.private_subnets
  control_plane_subnet_ids             = module.vpc.private_subnets
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = length(var.cluster_endpoint_public_access_cidrs) > 0
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  cluster_security_group_additional_rules = {
    bastion_https = {
      description              = "Allow the private SSM bastion to reach the EKS API"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = module.bastion.security_group_id
    }
  }

  # Enable IAM roles for service accounts (IRSA)
  enable_irsa = true

  # Core add-ons are managed explicitly. VPC CNI network-policy enforcement is
  # turned on because the NetworkPolicies in kubernetes/*/network-policy.yaml
  # are inert without it.
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      before_compute       = true
      most_recent          = true
      configuration_values = jsonencode({ env = { ENABLE_NETWORK_POLICY = "true" } })
    }
  }

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    main = {
      name           = "main-node-group"
      instance_types = ["t3.medium"] # 2 vCPU, 4GB RAM
      min_size       = 1
      max_size       = 3
      desired_size   = 2

      # We use the Bastion/SSM to access nodes, so no SSH key needed
      key_name = null
    }
  }

  # Allow the nodes to access ECR and other AWS services
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = var.cluster_name
    ManagedBy   = "terraform"
  }
}
