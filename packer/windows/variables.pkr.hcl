# -----------------------------------------------------------------------------
# Windows template. Same inputs as packer/linux (minus containers).
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
  default = "windows-2022"
}

variable "pkg_family" {
  type    = string
  default = "windows"
}

variable "ansible_python_interpreter" {
  type        = string
  description = "Python on the target for Ansible, when the default python3 is too old (e.g. SLES 15)"
  default     = ""
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

variable "syft_version" {
  type        = string
  description = "Syft release used to generate the SBOM on the build VM"
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

variable "azure_hyper_v_generation" {
  type        = string
  description = "Used by packer-build.sh to create the gallery image definition on first use"
  default     = "V2"
}

variable "azure_os_type" {
  type        = string
  description = "Used by packer-build.sh to create the gallery image definition on first use"
  default     = "Windows"
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

# ---- WinRM ---------------------------------------------------------------------
variable "winrm_username" {
  type        = string
  description = "Build-time local admin. Created by Packer (Azure) or user data (AWS); removed by sysprep/EC2Launch"
  default     = "packer"
}

variable "winrm_timeout" {
  type    = string
  default = "30m"
}
