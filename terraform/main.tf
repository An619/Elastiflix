# terraform/main.tf

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Keep the VPC and EKS nodes in three available AZs without assuming that
  # an account maps the same zone letters to the same physical locations.
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1" # Pinned version (Fixes Checkov CKV_TF_1)

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = local.availability_zones
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${var.cluster_name}-eks" = "shared"
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb"                       = "1"
    "kubernetes.io/cluster/${var.cluster_name}-eks" = "shared"
  }

  enable_nat_gateway = true
  single_nat_gateway = var.environment != "production"
  enable_vpn_gateway = false

  tags = {
    Environment = var.environment
    Terraform   = "true"
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

  # Networking: private endpoint access is always enabled. Public access is
  # enabled only when the operator supplies explicit non-worldwide CIDRs.
  vpc_id                             = module.vpc.vpc_id
  subnet_ids                         = module.vpc.private_subnets
  control_plane_subnet_ids           = module.vpc.private_subnets
  cluster_endpoint_private_access    = true
  cluster_endpoint_public_access     = length(var.cluster_endpoint_public_access_cidrs) > 0
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # The private SSM bastion is the default administrative path when public
  # endpoint CIDRs are not configured.
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
  }
}
