# =============================================================================
# One self-service EC2 instance from an approved golden image (AMI).
#
# Driven by vms/<name>.yaml through the vm-provision workflow, like the
# Azure module: scripts/portal/vm_tfvars.py writes request.auto.tfvars.json;
# platform settings (VPC, subnets, instance profile) come from TF_VAR_*.
# State: one file per VM (vms/<name>.tfstate) in the factory's S3 bucket.
# =============================================================================

terraform {
  required_version = ">= 1.10.0" # S3 native state locking
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.region
  # Every resource carries ManagedBy=image-factory: the vm-provision role
  # may only change resources with that tag.
  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    ManagedBy   = "image-factory"
    Owner       = var.owner
    Environment = var.environment
    RequestedBy = var.requested_by
    Image       = var.image
    Request     = "vms/${var.name}.yaml"
  }
  # The promote job publishes approved AMIs only:
  #   <prefix>/<image>/latest and <prefix>/<image>/versions/<version>
  catalog_parameter = (
    var.image_version == "latest"
    ? "${var.catalog_ssm_prefix}/${var.image}/latest"
    : "${var.catalog_ssm_prefix}/${var.image}/versions/${var.image_version}"
  )
  deployed_ami = terraform_data.image.output
  subnet_ids   = split(",", var.public_ip ? var.public_subnet_ids : var.private_subnet_ids)
  # Spread instances over the subnets (AZs) by name, so the choice is stable
  subnet_id = local.subnet_ids[parseint(substr(sha1(var.name), 0, 6), 16) % length(local.subnet_ids)]
}

data "aws_ssm_parameter" "image" {
  name = local.catalog_parameter
}

data "aws_ami" "image" {
  owners = ["self"]
  filter {
    name   = "image-id"
    values = [data.aws_ssm_parameter.image.insecure_value] # an AMI ID, not a secret
  }

  lifecycle {
    # Belt and braces: the catalog only holds promoted AMIs, but check the tag.
    postcondition {
      condition     = try(self.tags["Status"], "") == "approved"
      error_message = "AMI for ${var.image} ${var.image_version} isn't approved (it hasn't passed the vulnerability gate). Use 'latest' or a promoted version."
    }
    postcondition {
      condition     = self.platform_details != "Windows"
      error_message = "Windows images aren't available for self-service VMs yet."
    }
  }
}

# Pin the AMI the instance was created from. A newer "latest" doesn't
# replace a running instance; changing image or image_version does.
resource "terraform_data" "image" {
  input            = data.aws_ami.image.id
  triggers_replace = [var.image, var.image_version]

  lifecycle {
    ignore_changes = [input]
  }
}

data "aws_vpc" "workload" {
  id = var.vpc_id
}

resource "aws_key_pair" "this" {
  key_name   = "vm-${var.name}"
  public_key = var.ssh_public_key
}

# One security group per instance: everything from inside the VPC, SSH from
# the requested range when the instance has a public IP, all outbound.
resource "aws_security_group" "this" {
  name        = "vm-${var.name}"
  description = "Self-service VM ${var.name}"
  vpc_id      = var.vpc_id

  ingress {
    description = "From inside the workload VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.workload.cidr_block]
  }

  dynamic "ingress" {
    for_each = var.public_ip ? [var.allowed_ssh_cidr] : []
    content {
      description = "SSH from the allowed range"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vm-${var.name}" }
}

resource "aws_instance" "this" {
  ami                         = local.deployed_ami
  instance_type               = var.vm_size
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  associate_public_ip_address = var.public_ip
  key_name                    = aws_key_pair.this.key_name
  iam_instance_profile        = var.instance_profile

  # The image's default user varies by OS; create the requested admin user
  # with the requested key on first boot (cloud-init, every Linux image).
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
    hostname       = var.name
  })
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.os_disk_gb
    encrypted             = true
    kms_key_id            = var.kms_key_id != "" ? var.kms_key_id : null
    delete_on_termination = true
    tags                  = merge(local.tags, { Name = "vm-${var.name}-root" })
  }

  tags = { Name = var.name, ImageVersion = try(data.aws_ami.image.tags["ImageVersion"], "") }

  lifecycle {
    ignore_changes = [tags["ImageVersion"]] # records the version the instance was built from
    precondition {
      condition     = !var.public_ip || var.allowed_ssh_cidr != ""
      error_message = "A public IP needs allowed_ssh_cidr."
    }
  }
}
