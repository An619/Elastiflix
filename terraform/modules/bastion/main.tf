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

  # The bastion only needs HTTPS for Systems Manager through the NAT gateway.
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

  # No public IP: the host lives in a private subnet and reaches the SSM
  # service through the VPC's NAT gateway (see terraform/main.tf).
  # Session Manager only needs outbound 443.
  associate_public_ip_address = false

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

  # Ubuntu 22.04 AMIs may expose the preinstalled SSM agent as a package or
  # snap unit. Detect either supported name and fail visibly if neither exists.
  user_data = <<-EOF
              #!/bin/bash
              set -Eeuo pipefail
              if systemctl cat amazon-ssm-agent.service >/dev/null 2>&1; then
                ssm_unit=amazon-ssm-agent.service
              elif systemctl cat snap.amazon-ssm-agent.amazon-ssm-agent.service >/dev/null 2>&1; then
                ssm_unit=snap.amazon-ssm-agent.amazon-ssm-agent.service
              else
                echo "amazon-ssm-agent systemd unit not found" >&2
                exit 1
              fi
              systemctl enable --now "$ssm_unit"
              systemctl is-active --quiet "$ssm_unit"
              EOF

  tags = {
    Name        = "${var.cluster_name}-bastion"
    Environment = var.environment
  }
}
