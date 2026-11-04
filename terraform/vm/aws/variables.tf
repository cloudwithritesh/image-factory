# ---- From the VM request (request.auto.tfvars.json) ------------------------
variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,13}[a-z0-9]$", var.name))
    error_message = "The name value must be 3-15 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "owner" {
  type = string
}

variable "environment" {
  type = string
}

variable "requested_by" {
  type    = string
  default = "unknown"
}

variable "image" {
  description = "Approved image name (requests/<image>.yaml)"
  type        = string
}

variable "image_version" {
  description = "Image version, or latest (newest promoted)"
  type        = string
  default     = "latest"
}

variable "vm_size" {
  description = "EC2 instance type, resolved from the t-shirt size in catalog/vm.yaml"
  type        = string
}

variable "region" {
  type = string
}

variable "os_disk_gb" {
  type    = number
  default = 30
}

variable "admin_username" {
  type    = string
  default = "cloudadmin"
}

variable "ssh_public_key" {
  type = string
}

variable "public_ip" {
  type    = bool
  default = false
}

variable "allowed_ssh_cidr" {
  type    = string
  default = ""
  validation {
    condition     = var.allowed_ssh_cidr == "" || can(cidrnetmask(var.allowed_ssh_cidr))
    error_message = "The allowed_ssh_cidr value must be an IPv4 CIDR range."
  }
}

# ---- From the platform (TF_VAR_* in the workflow) ---------------------------
variable "vpc_id" {
  description = "Workload VPC (factory output VM_AWS_VPC_ID)"
  type        = string
}

variable "private_subnet_ids" {
  description = "Comma-separated private subnets (VM_AWS_PRIVATE_SUBNET_IDS)"
  type        = string
}

variable "public_subnet_ids" {
  description = "Comma-separated public subnets, used when public_ip = true (VM_AWS_PUBLIC_SUBNET_IDS)"
  type        = string
}

variable "instance_profile" {
  description = "Instance profile for SSM access (VM_AWS_INSTANCE_PROFILE)"
  type        = string
}

variable "kms_key_id" {
  description = "KMS key for the root volume (factory key, PKR_VAR_aws_kms_key_id); empty = AWS default key"
  type        = string
  default     = ""
}

variable "catalog_ssm_prefix" {
  description = "SSM prefix of the image catalog written by the promote job"
  type        = string
  default     = "/image-factory"
}
