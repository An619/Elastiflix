# terraform/main.tf

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1" # Pinned version (Fixes Checkov CKV_TF_1)

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

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
  subnet_id    = module.vpc.public_subnets[0]
  cluster_name = var.cluster_name
  environment  = var.environment
}
