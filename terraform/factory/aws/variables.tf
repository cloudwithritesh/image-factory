variable "aws_region" {
  description = "Region where images are built (copies to other regions are per request)"
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "image-factory"
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

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one."
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN (when create_github_oidc_provider = false)"
  type        = string
  default     = ""
}

variable "gitlab_url" {
  description = "GitLab instance URL (the OIDC issuer)"
  type        = string
  default     = "https://gitlab.com"
}

variable "gitlab_audience" {
  description = "aud claim of the GitLab ID token (must match id_tokens.AWS_ID_TOKEN.aud in .gitlab/ci/image-jobs.yml)"
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

variable "consumer_account_ids" {
  description = "AWS accounts that may launch the encrypted AMIs (granted KMS use; launch permission is set by the promote job)"
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for id in var.consumer_account_ids : can(regex("^\\d{12}$", id))])
    error_message = "The consumer_account_ids values must be 12-digit AWS account IDs."
  }
}

variable "catalog_ssm_prefix" {
  description = "SSM Parameter Store prefix for the image catalog"
  type        = string
  default     = "/image-factory"
}

variable "build_vpc_cidr" {
  description = "CIDR of the dedicated build VPC"
  type        = string
  default     = "10.250.0.0/20"
}

variable "tags" {
  description = "Extra tags for every resource"
  type        = map(string)
  default     = {}
}
