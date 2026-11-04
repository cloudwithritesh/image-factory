output "packer_role_arn" {
  value = aws_iam_role.packer.arn
}

output "build_subnet_id" {
  value = aws_subnet.build.id
}

output "ami_kms_key_arn" {
  value = aws_kms_key.ami.arn
}

output "ci_variables" {
  description = "Set these as GitHub repository variables or GitLab CI/CD variables (same names)"
  value = {
    AWS_BUILD_ROLE_ARN     = aws_iam_role.packer.arn
    PKR_VAR_aws_region     = var.aws_region
    PKR_VAR_aws_subnet_id  = aws_subnet.build.id
    PKR_VAR_aws_kms_key_id = aws_kms_key.ami.arn
    CATALOG_SSM_PREFIX     = var.catalog_ssm_prefix
    AWS_SHARE_ACCOUNT_IDS  = join(",", var.consumer_account_ids)

    # Self-service EC2 (terraform/vm/aws via vm-provision)
    VM_AWS_ROLE_ARN           = one(aws_iam_role.vm[*].arn)
    VM_AWS_VPC_ID             = aws_vpc.workload.id
    VM_AWS_PRIVATE_SUBNET_IDS = join(",", aws_subnet.private[*].id)
    VM_AWS_PUBLIC_SUBNET_IDS  = join(",", aws_subnet.public[*].id)
    VM_AWS_INSTANCE_PROFILE   = aws_iam_instance_profile.instance.name
  }
}

output "workload_vpc_id" {
  value = aws_vpc.workload.id
}
