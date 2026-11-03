locals {
  # Tags and labels applied everywhere, so any image can be traced back to
  # its request, commit and pipeline.
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
# AWS: EBS-backed AMI, encrypted with the factory CMK
# ---------------------------------------------------------------------------
source "amazon-ebs" "linux" {
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

  # GitLab.com SaaS runners reach the build VM over the internet. Packer
  # creates a temporary security group that only allows SSH from the
  # runner's own public IP.
  subnet_id                                 = var.aws_subnet_id != "" ? var.aws_subnet_id : null
  associate_public_ip_address               = true
  ssh_interface                             = "public_ip"
  temporary_security_group_source_public_ip = true
  ssh_username                              = var.aws_ssh_username

  imds_support = "v2.0"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  encrypt_boot = true
  kms_key_id   = var.aws_kms_key_id != "" ? var.aws_kms_key_id : null
  # Copies to other regions need a key in each region: { "eu-west-1" = "arn:aws:kms:..." }
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
# Azure: published straight into the Compute Gallery as an image version.
# The version is left out of "latest" until it passes the scan; the promote
# job then includes it.
# ---------------------------------------------------------------------------
source "azure-arm" "linux" {
  use_azure_cli_auth        = true # the CI job runs `az login --federated-token`
  subscription_id           = var.azure_subscription_id
  build_resource_group_name = var.azure_build_resource_group

  os_type         = "Linux"
  image_publisher = var.azure_image_publisher
  image_offer     = var.azure_image_offer
  image_sku       = var.azure_image_sku
  vm_size         = var.azure_vm_size

  # Restrict SSH on the temporary build VM to the runner's public IP
  # (the CI job detects it and sets PKR_VAR_azure_allowed_inbound_ip_addresses).
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

# ---------------------------------------------------------------------------
# Docker: container base image, pushed to the CI platform's registry
# (GHCR or the GitLab container registry) as
# :candidate-<version>. The promote job adds the real tags.
# ---------------------------------------------------------------------------
source "docker" "linux" {
  image  = var.docker_base_image
  commit = true
  changes = [
    "LABEL org.opencontainers.image.title=${var.image_name}",
    "LABEL org.opencontainers.image.version=${var.image_version}",
    "LABEL org.opencontainers.image.revision=${var.git_sha}",
    "LABEL org.opencontainers.image.vendor=${var.image_owner}",
    "LABEL org.opencontainers.image.base.name=${var.docker_base_image}",
    "LABEL org.opencontainers.image.source=${var.docker_source_url}",
    "ENV LANG=C.UTF-8",
    "CMD [\"/bin/bash\"]",
  ]
}
