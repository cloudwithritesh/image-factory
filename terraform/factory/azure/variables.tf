variable "subscription_id" {
  description = "Factory subscription"
  type        = string
}

variable "location" {
  description = "Region for the gallery and the build resource group"
  type        = string
  default     = "southeastasia"
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "image-factory"
}

variable "gallery_name" {
  description = "Compute Gallery name (letters, digits, underscores and periods only)"
  type        = string
  default     = "sig_image_factory"
  validation {
    condition     = can(regex("^[A-Za-z0-9_.]{1,80}$", var.gallery_name))
    error_message = "The gallery_name value may contain only letters, digits, underscores and periods."
  }
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose Actions may build and promote. Empty = GitHub not used."
  type        = string
  default     = ""
}

variable "github_owner_id" {
  description = "Numeric ID of the GitHub repository owner (gh api repos/OWNER/REPO -q .owner.id). Set with github_repository_id for immutable OIDC subjects."
  type        = string
  default     = ""
}

variable "github_repository_id" {
  description = "Numeric ID of the GitHub repository (gh api repos/OWNER/REPO -q .id). Required for repos created after 2026-07-15."
  type        = string
  default     = ""
  validation {
    condition     = var.github_repository_id == "" || can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "The github_repository_id value must be numeric."
  }
}

variable "github_ref" {
  description = "Branch allowed to build on GitHub"
  type        = string
  default     = "main"
}

variable "gitlab_url" {
  description = "GitLab instance URL (the OIDC issuer)"
  type        = string
  default     = "https://gitlab.com"
}

variable "gitlab_project_path" {
  description = "Full path of the GitLab project, e.g. my-group/image-factory. Empty = GitLab not used."
  type        = string
  default     = ""
}

variable "gitlab_ref" {
  description = "Protected branch allowed to build and promote"
  type        = string
  default     = "main"
}

variable "tags" {
  description = "Extra tags for every resource"
  type        = map(string)
  default     = {}
}

variable "workload_vnet_cidr" {
  description = "Address space of the VNet that portal-created VMs join"
  type        = string
  default     = "10.60.0.0/16"
}

variable "tf_state_storage_account_id" {
  description = "Resource ID of the Terraform state storage account; grants the CI identity blob access for VM state"
  type        = string
  default     = ""
}
