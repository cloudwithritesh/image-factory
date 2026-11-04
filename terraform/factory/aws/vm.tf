# =============================================================================
# Self-service EC2 instances (terraform/vm/aws, run by vm-provision)
#   - workload VPC: public + private subnets in two AZs, optional NAT gateway
#   - IAM role for the vm-provision workflow (main branch only), separate
#     from the Packer role so each pipeline has only what it needs
#   - instance profile for the instances: SSM Session Manager access
# =============================================================================

locals {
  workload_azs = slice(data.aws_availability_zones.available.names, 0, 2)
  vm_name_tag  = "${var.name_prefix}-vm"
}

# ---- Workload network -------------------------------------------------------
resource "aws_vpc" "workload" {
  cidr_block           = var.workload_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.name_prefix}-workloads" }
}

# Nothing is allowed by the default security group; every instance gets its
# own group from terraform/vm/aws.
resource "aws_default_security_group" "workload" {
  vpc_id = aws_vpc.workload.id
}

resource "aws_internet_gateway" "workload" {
  vpc_id = aws_vpc.workload.id
  tags   = { Name = "${var.name_prefix}-workloads" }
}

resource "aws_subnet" "public" {
  count                   = length(local.workload_azs)
  vpc_id                  = aws_vpc.workload.id
  cidr_block              = cidrsubnet(var.workload_vpc_cidr, 4, count.index)
  availability_zone       = local.workload_azs[count.index]
  map_public_ip_on_launch = false # public IPs only when a request asks for one
  tags                    = { Name = "${var.name_prefix}-workloads-public-${local.workload_azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "private" {
  count             = length(local.workload_azs)
  vpc_id            = aws_vpc.workload.id
  cidr_block        = cidrsubnet(var.workload_vpc_cidr, 4, count.index + 8)
  availability_zone = local.workload_azs[count.index]
  tags              = { Name = "${var.name_prefix}-workloads-private-${local.workload_azs[count.index]}", Tier = "private" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.workload.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.workload.id
  }
  tags = { Name = "${var.name_prefix}-workloads-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private instances reach package mirrors and SSM through one NAT gateway
# (about USD 35/month plus data). Without it, private instances have no
# outbound internet; set workload_nat_gateway = false only if you add
# VPC endpoints or a proxy instead.
resource "aws_eip" "nat" {
  count  = var.workload_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-workloads-nat" }
}

resource "aws_nat_gateway" "workload" {
  count         = var.workload_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.name_prefix}-workloads" }
  depends_on    = [aws_internet_gateway.workload]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.workload.id
  dynamic "route" {
    for_each = var.workload_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.workload[0].id
    }
  }
  tags = { Name = "${var.name_prefix}-workloads-private" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---- Instance profile (what the instances may do) -----------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name_prefix}-instance"
  description        = "Self-service EC2 instances: SSM Session Manager and patching"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-instance"
  role = aws_iam_role.instance.name
}

# ---- Role for the vm-provision workflow ----------------------------------------
# Trusted for the main branch only: VM changes apply after a reviewed merge.
data "aws_iam_policy_document" "vm_trust" {
  count = local.use_github ? 1 : 0
  statement {
    sid     = "GitHubActionsMain"
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
      values   = ["${local.github_subject_prefix}:ref:refs/heads/${var.github_ref}"]
    }
  }
}

resource "aws_iam_role" "vm" {
  count                = local.use_github ? 1 : 0
  name                 = "${var.name_prefix}-vm-provision"
  description          = "Assumed by the vm-provision workflow to create and remove self-service EC2 instances"
  assume_role_policy   = data.aws_iam_policy_document.vm_trust[0].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "vm" {
  statement {
    sid       = "Read"
    actions   = ["ec2:Describe*", "ec2:GetEbsEncryptionByDefault", "ec2:GetEbsDefaultKmsKeyId"]
    resources = ["*"]
  }

  # Instances (and tags) must carry ManagedBy=image-factory (the module's
  # default_tags), and the role may only change resources that carry it.
  statement {
    sid = "CreateTagged"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateTags",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/ManagedBy"
      values   = ["image-factory"]
    }
  }

  statement {
    sid       = "CreateInstanceSupport"
    actions   = ["ec2:CreateSecurityGroup", "ec2:ImportKeyPair"]
    resources = ["*"]
  }

  # RunInstances also touches existing resources (AMI, subnet, SG, key pair,
  # volumes, network interfaces) that the request-tag condition can't cover.
  statement {
    sid     = "RunInstancesReferences"
    actions = ["ec2:RunInstances"]
    resources = [
      "arn:${local.partition}:ec2:*::image/*",
      "arn:${local.partition}:ec2:*:${local.account_id}:subnet/*",
      "arn:${local.partition}:ec2:*:${local.account_id}:security-group/*",
      "arn:${local.partition}:ec2:*:${local.account_id}:key-pair/*",
      "arn:${local.partition}:ec2:*:${local.account_id}:network-interface/*",
      "arn:${local.partition}:ec2:*:${local.account_id}:volume/*",
    ]
  }

  statement {
    sid = "ChangeOwnResources"
    actions = [
      "ec2:TerminateInstances",
      "ec2:StopInstances",
      "ec2:StartInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyInstanceMetadataOptions",
      "ec2:ModifyVolume",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:DeleteKeyPair",
      "ec2:DeleteTags",
      "ec2:AssociateIamInstanceProfile",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/ManagedBy"
      values   = ["image-factory"]
    }
  }

  statement {
    sid       = "PassInstanceRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.instance.arn]
  }

  statement {
    sid       = "ReadInstanceProfile"
    actions   = ["iam:GetInstanceProfile", "iam:GetRole"]
    resources = [aws_iam_instance_profile.instance.arn, aws_iam_role.instance.arn]
  }

  # Launch from encrypted AMIs and encrypt the root volume with the factory key
  statement {
    sid = "UseFactoryKey"
    actions = [
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncrypt*",
    ]
    resources = [aws_kms_key.ami.arn]
  }

  statement {
    sid       = "ReadImageCatalog"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.partition}:ssm:*:${local.account_id}:parameter${var.catalog_ssm_prefix}/*"]
  }

  dynamic "statement" {
    for_each = var.tf_state_bucket != "" ? [1] : []
    content {
      sid       = "VmState"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["arn:${local.partition}:s3:::${var.tf_state_bucket}/vms/*"]
    }
  }

  dynamic "statement" {
    for_each = var.tf_state_bucket != "" ? [1] : []
    content {
      sid       = "VmStateList"
      actions   = ["s3:ListBucket"]
      resources = ["arn:${local.partition}:s3:::${var.tf_state_bucket}"]
      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["vms/*"]
      }
    }
  }
}

resource "aws_iam_role_policy" "vm" {
  count  = local.use_github ? 1 : 0
  name   = "vm-provision"
  role   = aws_iam_role.vm[0].id
  policy = data.aws_iam_policy_document.vm.json
}
