# -----------------------------------------------------------------------------
# Variables come from two places:
#   1. build/<image>/variables.pkrvars.json, written by scripts/imagefactory.py
#      from the image request (what to build)
#   2. PKR_VAR_* environment variables, set as GitLab CI/CD variables from the
#      Terraform factory outputs (where to build: accounts, networks, galleries)
# Every variable has a default so a single target can be built or validated
# with -only, without setting the other clouds' variables.
# -----------------------------------------------------------------------------

# ---- Image identity (from the request) --------------------------------------
variable "image_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$", var.image_name))
    error_message = "The image_name value must be lowercase letters, digits and hyphens."
  }
}

variable "image_version" {
  type        = string
  description = "Semantic version shared by every target, e.g. 2026.1103.42"
  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+$", var.image_version))
    error_message = "The image_version value must be MAJOR.MINOR.PATCH (integers), as Azure galleries require."
  }
}

variable "image_owner" {
  type    = string
  default = "platform-engineering"
}

variable "image_description" {
  type    = string
  default = "Golden image built by the image factory"
}

variable "os_key" {
  type    = string
  default = "ubuntu-2404"
}

variable "request_labels" {
  type    = map(string)
  default = {}
}

variable "git_sha" {
  type    = string
  default = "local"
}

variable "pipeline_url" {
  type    = string
  default = "local"
}

variable "output_dir" {
  type        = string
  description = "Where SBOMs and the manifest are written on the machine running Packer"
  default     = "build/output"
}

# ---- Ansible (from the request) ---------------------------------------------
variable "ansible_vm_vars_file" {
  type    = string
  default = ""
}

variable "ansible_vm_skip_tags" {
  type    = string
  default = ""
}

variable "ansible_container_vars_file" {
  type    = string
  default = ""
}

variable "ansible_container_skip_tags" {
  type    = string
  default = ""
}

variable "syft_version" {
  type        = string
  description = "Syft release used to generate the SBOM on VM builds"
  default     = "1.55.0"
}

# ---- AWS ---------------------------------------------------------------------
variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "aws_source_ami_filter_name" {
  type    = string
  default = ""
}

variable "aws_source_ami_owners" {
  type    = list(string)
  default = []
}

variable "aws_ssh_username" {
  type    = string
  default = "ubuntu"
}

variable "aws_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "aws_root_volume_gb" {
  type    = number
  default = 20
}

variable "aws_ami_copy_regions" {
  type    = list(string)
  default = []
}

variable "aws_region_kms_key_ids" {
  type        = map(string)
  description = "KMS key per copy region (required by Packer when aws_ami_copy_regions is set)"
  default     = {}
}

variable "aws_subnet_id" {
  type        = string
  description = "Public subnet in the factory build VPC (Terraform output build_subnet_id)"
  default     = ""
}

variable "aws_kms_key_id" {
  type        = string
  description = "Customer-managed KMS key for AMI encryption, so AMIs can be shared across accounts"
  default     = ""
}

# ---- Azure -------------------------------------------------------------------
variable "azure_subscription_id" {
  type    = string
  default = ""
}

variable "azure_build_resource_group" {
  type        = string
  description = "Existing resource group for temporary build VMs (Terraform output)"
  default     = ""
}

variable "azure_gallery_resource_group" {
  type    = string
  default = ""
}

variable "azure_gallery_name" {
  type    = string
  default = ""
}

variable "azure_gallery_location" {
  type    = string
  default = "southeastasia"
}

variable "azure_gallery_image_definition" {
  type    = string
  default = ""
}

variable "azure_image_publisher" {
  type    = string
  default = ""
}

variable "azure_image_offer" {
  type    = string
  default = ""
}

variable "azure_image_sku" {
  type    = string
  default = ""
}

variable "azure_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "azure_allowed_inbound_ip_addresses" {
  type    = list(string)
  default = []
}

variable "azure_replication_regions" {
  type    = list(string)
  default = []
}

# ---- Docker ------------------------------------------------------------------
variable "docker_base_image" {
  type    = string
  default = "docker.io/library/ubuntu:24.04"
}

variable "docker_repository" {
  type        = string
  description = "Registry path the image is pushed to, e.g. ghcr.io/org/image-factory/images/ubuntu-2404-base"
  default     = ""
}

variable "docker_source_url" {
  type        = string
  description = "Repository URL for the org.opencontainers.image.source label (links GHCR packages to the repo)"
  default     = ""
}

variable "docker_registry" {
  type    = string
  default = "ghcr.io"
}

variable "docker_registry_username" {
  type      = string
  default   = ""
  sensitive = true
}

variable "docker_registry_password" {
  type      = string
  default   = ""
  sensitive = true
}
