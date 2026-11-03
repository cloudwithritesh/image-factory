# =============================================================================
# Image factory: AWS foundation
#   - OIDC trust for GitHub Actions and/or GitLab.com + IAM role for Packer
#     builds and promotion (both platforms can be trusted at the same time,
#     which makes a later move from one to the other a non-event)
#   - Dedicated build VPC with a public subnet (GitLab SaaS runners SSH in)
#   - Customer-managed KMS key so encrypted AMIs can be shared
# Apply once per factory account, then copy output "ci_variables" into
# GitHub repository variables or GitLab CI/CD variables (same names).
# =============================================================================

terraform {
  required_version = ">= 1.10.0" # S3 native state locking (use_lockfile)
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # Partial config: pass bucket/key/region at init (see README). State lives
  # in your cloud, not in the CI platform, so switching CI doesn't touch it.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = merge(var.tags, { ManagedBy = "terraform", Component = "image-factory" })
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
  use_gitlab  = var.gitlab_project_path != ""
  use_github  = var.github_repository != ""
  gitlab_host = trimprefix(var.gitlab_url, "https://")

  # GitHub subject claims: builds run on the branch; promotion jobs run in
  # environments, which changes the subject.
  github_subjects = [
    "repo:${var.github_repository}:ref:refs/heads/${var.github_ref}",
    "repo:${var.github_repository}:environment:images-aws",
    "repo:${var.github_repository}:environment:images-aws-approval",
  ]
  github_provider_arn = (
    var.create_github_oidc_provider
    ? one(aws_iam_openid_connect_provider.github[*].arn)
    : var.github_oidc_provider_arn
  )
}

# ---- OIDC providers ---------------------------------------------------------
resource "aws_iam_openid_connect_provider" "gitlab" {
  count          = local.use_gitlab ? 1 : 0
  url            = var.gitlab_url
  client_id_list = [var.gitlab_audience]
}

# An account can have only one provider per URL. If GitHub OIDC is already
# set up, set create_github_oidc_provider = false and pass its ARN.
resource "aws_iam_openid_connect_provider" "github" {
  count          = local.use_github && var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  dynamic "statement" {
    for_each = local.use_github ? [1] : []
    content {
      sid     = "GitHubActionsMainAndPromotion"
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [local.github_provider_arn]
      }
      condition {
        test     = "StringEquals"
        variable = "token.actions.githubusercontent.com:aud"
        values   = ["sts.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "token.actions.githubusercontent.com:sub"
        values   = local.github_subjects
      }
    }
  }

  dynamic "statement" {
    for_each = local.use_gitlab ? [1] : []
    content {
      sid     = "GitLabProtectedBranch"
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [one(aws_iam_openid_connect_provider.gitlab[*].arn)]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.gitlab_host}:aud"
        values   = [var.gitlab_audience]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.gitlab_host}:sub"
        values   = ["project_path:${var.gitlab_project_path}:ref_type:branch:ref:${var.gitlab_ref}"]
      }
    }
  }
}

resource "aws_iam_role" "packer" {
  name                 = "${var.name_prefix}-packer"
  description          = "Assumed by the image factory pipelines to build and promote AMIs"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 7200

  lifecycle {
    precondition {
      condition     = local.use_github || local.use_gitlab
      error_message = "Set github_repository, gitlab_project_path, or both."
    }
    precondition {
      condition     = !local.use_github || var.create_github_oidc_provider || var.github_oidc_provider_arn != ""
      error_message = "Set github_oidc_provider_arn when create_github_oidc_provider is false."
    }
  }
}

# Permissions Packer's amazon-ebs builder needs, plus promotion (tags,
# launch permissions, SSM catalog parameters).
data "aws_iam_policy_document" "packer" {
  statement {
    sid = "PackerEc2"
    actions = [
      "ec2:AttachVolume",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CopyImage",
      "ec2:CreateImage",
      "ec2:CreateKeyPair",
      "ec2:CreateSecurityGroup",
      "ec2:CreateSnapshot",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:DeleteKeyPair",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSnapshot",
      "ec2:DeleteVolume",
      "ec2:DeregisterImage",
      "ec2:DescribeImageAttribute",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeRegions",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSnapshots",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "ec2:DescribeVpcs",
      "ec2:DetachVolume",
      "ec2:GetPasswordData",
      "ec2:ModifyImageAttribute",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifySnapshotAttribute",
      "ec2:RegisterImage",
      "ec2:RunInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid = "UseFactoryKey"
    actions = [
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = [aws_kms_key.ami.arn]
  }

  statement {
    sid       = "CatalogParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:PutParameter", "ssm:AddTagsToResource"]
    resources = ["arn:${local.partition}:ssm:*:${local.account_id}:parameter${var.catalog_ssm_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "packer" {
  name   = "packer-build-and-promote"
  role   = aws_iam_role.packer.id
  policy = data.aws_iam_policy_document.packer.json
}

# ---- KMS key for AMI encryption ---------------------------------------------
data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  dynamic "statement" {
    for_each = length(var.consumer_account_ids) > 0 ? [1] : []
    content {
      sid = "ConsumersLaunchEncryptedAmis"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:ReEncrypt*",
        "kms:CreateGrant",
      ]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = [for id in var.consumer_account_ids : "arn:${local.partition}:iam::${id}:root"]
      }
    }
  }
}

resource "aws_kms_key" "ami" {
  description             = "Image factory: AMI and snapshot encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "ami" {
  name          = "alias/${var.name_prefix}-ami"
  target_key_id = aws_kms_key.ami.key_id
}

# ---- Build network ----------------------------------------------------------
# Temporary build instances only. Packer opens SSH from the runner's IP alone.
resource "aws_vpc" "build" {
  cidr_block           = var.build_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.name_prefix}-build" }
}

resource "aws_internet_gateway" "build" {
  vpc_id = aws_vpc.build.id
  tags   = { Name = "${var.name_prefix}-build" }
}

resource "aws_subnet" "build" {
  vpc_id                  = aws_vpc.build.id
  cidr_block              = cidrsubnet(var.build_vpc_cidr, 4, 0)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name_prefix}-build-public" }
}

resource "aws_route_table" "build" {
  vpc_id = aws_vpc.build.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.build.id
  }
  tags = { Name = "${var.name_prefix}-build-public" }
}

resource "aws_route_table_association" "build" {
  subnet_id      = aws_subnet.build.id
  route_table_id = aws_route_table.build.id
}

# The default security group allows nothing.
resource "aws_default_security_group" "build" {
  vpc_id = aws_vpc.build.id
}
