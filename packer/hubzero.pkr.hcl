packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

# AL2023 base AMI (Amazon-owned)
data "amazon-ami" "al2023" {
  region = var.aws_region
  filters = {
    name                = "al2023-ami-2023.*-x86_64"
    virtualization-type = "hvm"
  }
  owners      = ["137112412989"]
  most_recent = true
}

source "amazon-ebs" "hubzero" {
  region        = var.aws_region
  source_ami    = data.amazon-ami.al2023.id
  instance_type = var.instance_type
  ssh_username  = "ec2-user"

  ami_name        = "hubzero-base-{{isotime \"2006-01-02\"}}"
  ami_description = "HubZero base AMI — AL2023, Apache 2.4, PHP 8.2, MariaDB client, CWAgent"

  tags = {
    Project   = "hubzero"
    GitSHA    = "{{ env `GIT_SHA` }}"
    BaseAMI   = data.amazon-ami.al2023.id
    BuildDate = "{{isotime \"2006-01-02\"}}"
  }
}

build {
  sources = ["source.amazon-ebs.hubzero"]

  provisioner "shell" {
    script = "../scripts/bake.sh"
    environment_vars = [
      "GIT_SHA={{ env `GIT_SHA` }}",
    ]
  }
}
