terraform {
  required_version = ">= 1.3.0, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.44"
    }
  }
}

########################################
#              Variables               #
########################################

variable "aws_region" {
  description = "AWS region to deploy resources (e.g., us-west-2)"
  type        = string
}

variable "aws_access_key" {
  description = "AWS access key (or rely on environment/role)"
  type        = string
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS secret key (or rely on environment/role)"
  type        = string
  sensitive   = true
}

variable "public_key_path" {
  description = "Path to your SSH public key (e.g., ~/.ssh/id_rsa.pub)"
  type        = string
}

variable "project" {
  description = "Name prefix for resources"
  type        = string
  default     = "openshift-jump"
}

########################################
#              Provider                #
########################################

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

########################################
#            Data Sources              #
########################################

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

########################################
#           IAM & Key Pair             #
########################################

resource "aws_key_pair" "jump" {
  key_name   = "${var.project}-key"
  public_key = file(var.public_key_path)
}

resource "aws_iam_instance_profile" "jump" {
  name = "${var.project}-profile"
  role = aws_iam_role.jump.name
}

########################################
#           Security Group             #
########################################

resource "aws_security_group" "jump" {
  name        = "${var.project}-sg"
  description = "Allow SSH and outbound"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-sg"
  }
}

########################################
#           Route53 Hosted Zone        #
########################################

resource "aws_route53_zone" "softekh" {
  name    = "softekh.com"
  comment = "Managed by Terraform"
}

########################################
#         User-Data (Bootstrap)        #
########################################

locals {
  user_data = <<EOF
#!/bin/bash

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1
set -euxo pipefail

echo "User-data: Started"

# System update & tools
dnf update -y || echo "WARNING: update failed"
dnf install -y wget tar jq awscli || echo "WARNING: install failed"

# Set up directories on the EBS-backed /home
INSTALLER_BASE="/home/ec2-user"
OCP4_DIR="$${INSTALLER_BASE}/ocp4-installer"
OKD4_DIR="$${INSTALLER_BASE}/okd4-installer"
mkdir -p "$${OCP4_DIR}" "$${OKD4_DIR}"

# Download & extract OCP4 installer directly into its folder
echo "Downloading & extracting OCP4 installer..."
OCP4_URL="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-install-linux.tar.gz"
wget -q -O "$${OCP4_DIR}/ocp4.tar.gz" "$${OCP4_URL}"
tar -C "$${OCP4_DIR}" -xf "$${OCP4_DIR}/ocp4.tar.gz"
mv "$${OCP4_DIR}/openshift-install" "$${OCP4_DIR}/openshift-install-ocp4"
rm -f "$${OCP4_DIR}/ocp4.tar.gz"

# Download & extract OKD4 installer
echo "Downloading & extracting OKD4 installer..."
OKD4_VER="4.15.0-0.okd-2024-03-10-010116"
wget -q -O "$${OKD4_DIR}/okd4.tar.gz" "https://github.com/okd-project/okd/releases/download/$${OKD4_VER}/openshift-install-linux-$${OKD4_VER}.tar.gz"
tar -C "$${OKD4_DIR}" -xf "$${OKD4_DIR}/okd4.tar.gz"
mv "$${OKD4_DIR}/openshift-install" "$${OKD4_DIR}/openshift-install-okd4"
rm -f "$${OKD4_DIR}/okd4.tar.gz"

# Download & install oc & kubectl
echo "Installing oc & kubectl clients..."
CLIENT_TARBALL_DIR="$${INSTALLER_BASE}/clients"
mkdir -p "$${CLIENT_TARBALL_DIR}"
wget -q -O "$${CLIENT_TARBALL_DIR}/clients.tar.gz" "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux.tar.gz"
tar -C /usr/local/bin -xf "$${CLIENT_TARBALL_DIR}/clients.tar.gz"
chmod +x /usr/local/bin/oc /usr/local/bin/kubectl
rm -rf "$${CLIENT_TARBALL_DIR}"

# AWS CLI config for ec2-user
mkdir -p "$${INSTALLER_BASE}/.aws"
cat <<AWSCONF > "$${INSTALLER_BASE}/.aws/config"
[default]
region=${var.aws_region}
output=json
AWSCONF

chown -R ec2-user:ec2-user "$${INSTALLER_BASE}"

echo "User-data: Finished"
EOF
}

########################################
#            EC2 Instance              #
########################################

resource "aws_instance" "jump" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t2.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.jump.id]
  key_name                    = aws_key_pair.jump.key_name
  iam_instance_profile        = aws_iam_instance_profile.jump.name
  user_data                   = local.user_data
  user_data_replace_on_change = true

  tags = {
    Name = "${var.project}-jump"
  }
}

########################################
#               Outputs                #
########################################

output "jump_server_public_ip" {
  description = "Public IP of the jump server"
  value       = aws_instance.jump.public_ip
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh ec2-user@${aws_instance.jump.public_ip} -i ~/.ssh/id_rsa"
}

output "route53_zone_id" {
  description = "Route53 Zone ID"
  value       = aws_route53_zone.softekh.zone_id
}

output "route53_name_servers" {
  description = "Name servers to delegate"
  value       = aws_route53_zone.softekh.name_servers
}

output "view_user_data_log" {
  description = "To view user-data log"
  value       = "cat /var/log/user-data.log"
}

output "view_cloud_init_log" {
  description = "To view cloud-init log"
  value       = "sudo cat /var/log/cloud-init-output.log"
}
