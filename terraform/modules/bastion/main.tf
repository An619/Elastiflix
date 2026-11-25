data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "bastion" {
  name        = "${var.cluster_name}-bastion-sg"
  description = "Security group for SSM bastion host"
  vpc_id      = var.vpc_id

  # Checkov Fix: Restricted egress and added description
  # TCP/80 is required: Ubuntu APT mirrors are HTTP-only, so without it
  # user_data `apt-get update` hangs and the instance never bootstraps.
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP outbound for APT mirrors"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS outbound for SSM and updates"
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
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
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
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  # The bastion lives in a public subnet (see terraform/main.tf) but the
  # VPC module does not set map_public_ip_on_launch, so without this the
  # instance gets no public IP and SSM Session Manager cannot reach it.
  associate_public_ip_address = true

  # Checkov Fixes:
  monitoring    = true
  ebs_optimized = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # Enforce IMDSv2
  }

  root_block_device {
    volume_size = 8
    encrypted   = true
  }

  # Ubuntu 22.04 AMIs already ship amazon-ssm-agent, so no manual install
  # is needed. Keep user_data minimal: just ensure the agent is running.
  user_data = <<-EOF
              #!/bin/bash
              sudo apt-get update -y
              sudo systemctl enable amazon-ssm-agent || true
              sudo systemctl start amazon-ssm-agent || true
              EOF

  tags = {
    Name        = "${var.cluster_name}-bastion"
    Environment = var.environment
  }
}
