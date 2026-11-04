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
  description = "Approved image name = gallery image definition"
  type        = string
}

variable "image_version" {
  description = "Gallery image version, or latest (newest promoted)"
  type        = string
  default     = "latest"
}

variable "vm_size" {
  description = "Azure size, resolved from the t-shirt size in catalog/vm.yaml"
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
  default = "azureuser"
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
variable "subscription_id" {
  type = string
}

variable "resource_group_name" {
  description = "VM landing-zone resource group (factory output VM_RESOURCE_GROUP)"
  type        = string
}

variable "subnet_id" {
  description = "Workload subnet (factory output VM_SUBNET_ID)"
  type        = string
}

variable "gallery_resource_group" {
  type = string
}

variable "gallery_name" {
  type = string
}
