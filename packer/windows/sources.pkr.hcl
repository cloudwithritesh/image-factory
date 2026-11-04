locals {
  # Same tags as the Linux template, so every image traces back to its
  # request, commit and pipeline.
  common_tags = merge(var.request_labels, {
    ImageName    = var.image_name
    ImageVersion = var.image_version
    ImageOwner   = var.image_owner
    OsKey        = var.os_key
    GitSha       = var.git_sha
    Pipeline     = var.pipeline_url
    BuiltBy      = "image-factory"
    Status       = "candidate" # changed to "approved" by the promote job
  })

  azure_replication_regions = distinct(concat([var.azure_gallery_location], var.azure_replication_regions))
}

# ---------------------------------------------------------------------------
# AWS: Windows AMI. User data turns on WinRM over HTTPS; Packer reads the
# generated Administrator password with the temporary key pair.
# ---------------------------------------------------------------------------
source "amazon-ebs" "windows" {
  region          = var.aws_region
  instance_type   = var.aws_instance_type
  ami_name        = "${var.image_name}-${var.image_version}"
  ami_description = "${var.image_description} (${var.image_version})"
  ami_regions     = var.aws_ami_copy_regions

  source_ami_filter {
    filters = {
      name                = var.aws_source_ami_filter_name
      virtualization-type = "hvm"
      root-device-type    = "ebs"
      architecture        = "x86_64"
    }
    owners      = var.aws_source_ami_owners
    most_recent = true
  }

  subnet_id                                 = var.aws_subnet_id != "" ? var.aws_subnet_id : null
  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true
  user_data_file                            = "${path.root}/../../scripts/windows/aws-userdata.ps1"

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_use_ssl  = true
  winrm_insecure = true # self-signed listener certificate on a throwaway VM
  winrm_use_ntlm = true # Basic auth is turned off in the user data
  winrm_timeout  = var.winrm_timeout

  imds_support = "v2.0"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  encrypt_boot       = true
  kms_key_id         = var.aws_kms_key_id != "" ? var.aws_kms_key_id : null
  region_kms_key_ids = var.aws_region_kms_key_ids

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.aws_root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags          = local.common_tags
  snapshot_tags = local.common_tags
  run_tags = {
    Name    = "packer-build-${var.image_name}-${var.image_version}"
    BuiltBy = "image-factory"
  }
}

# ---------------------------------------------------------------------------
# Azure: published into the Compute Gallery, excluded from "latest" until
# the promote job approves it. azure-arm sets up WinRM over HTTPS itself
# (temporary Key Vault in the build resource group for the certificate).
# ---------------------------------------------------------------------------
source "azure-arm" "windows" {
  use_azure_cli_auth        = true
  subscription_id           = var.azure_subscription_id
  build_resource_group_name = var.azure_build_resource_group

  os_type         = "Windows"
  image_publisher = var.azure_image_publisher
  image_offer     = var.azure_image_offer
  image_sku       = var.azure_image_sku
  vm_size         = var.azure_vm_size

  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_use_ntlm = true # same auth as Ansible (ansible_winrm_transport=ntlm)
  winrm_timeout  = var.winrm_timeout

  # WinRM (5986) on the build VM is reachable from the runner's IP only
  allowed_inbound_ip_addresses = var.azure_allowed_inbound_ip_addresses

  shared_image_gallery_destination {
    subscription         = var.azure_subscription_id
    resource_group       = var.azure_gallery_resource_group
    gallery_name         = var.azure_gallery_name
    image_name           = var.azure_gallery_image_definition
    image_version        = var.image_version
    replication_regions  = local.azure_replication_regions
    storage_account_type = "Standard_LRS"
  }
  shared_gallery_image_version_exclude_from_latest = true

  azure_tags = local.common_tags
}
