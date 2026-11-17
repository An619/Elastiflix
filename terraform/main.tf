
# ------------------------------------------------------------------
# 1. VPC Network Layer (Cost Optimization: Single NAT Gateway)
# ------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = var.environment != "production"
  one_nat_gateway_per_az = var.environment == "production"
  enable_vpn_gateway     = false

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

# ------------------------------------------------------------------
# 2. Bastion Host — Ubuntu 22.04 ARM64 (Cost-Optimized)
# ------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's AWS Account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"] # ARM64 for t4g.nano
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "bastion" {
  name        = "${var.cluster_name}-bastion-sg"
  description = "Security group for SSM bastion host"
  vpc_id      = module.vpc.vpc_id

  # No inbound rules needed (Access is purely via AWS SSM Session Manager)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-bastion-sg"
    Environment = var.environment
  }
}

resource "aws_iam_role" "bastion" {
  name = "${var.cluster_name}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.cluster_name}-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.bastion_instance_type
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  # user_data to install and start the SSM Agent on Ubuntu ARM64
  user_data = <<-EOF
              #!/bin/bash
              sudo apt-get update -y
              sudo apt-get install -y wget
              wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_arm64/amazon-ssm-agent.deb
              sudo dpkg -i amazon-ssm-agent.deb
              sudo systemctl enable amazon-ssm-agent
              sudo systemctl start amazon-ssm-agent
              EOF

  tags = {
    Name        = "${var.cluster_name}-bastion"
    Environment = var.environment
  }
}

# ------------------------------------------------------------------
# 3. Output: Command to connect to the bastion host
# ------------------------------------------------------------------
output "bastion_ssm_command" {
  description = "Command to start an SSM session with the bastion host"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.aws_region}"
}
