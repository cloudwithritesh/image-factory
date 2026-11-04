# =============================================================================
# Image factory: Azure foundation
#   - Resource groups for temporary build VMs and for the Compute Gallery
#   - Azure Compute Gallery with one image definition per OS in catalog/os.yaml
#   - Entra ID app with federated credentials for GitHub Actions and/or
#     GitLab.com (no secrets)
# Apply once per factory subscription, then copy output "ci_variables" into
# GitHub repository variables or GitLab CI/CD variables (same names).
# =============================================================================

terraform {
  required_version = ">= 1.7.0" # removed blocks
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
  # Partial config: pass storage account/container/key at init (see README).
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azuread" {}

data "azurerm_client_config" "current" {}

locals {
  tags = merge(var.tags, { ManagedBy = "terraform", Component = "image-factory" })
}

# ---- Resource groups --------------------------------------------------------
resource "azurerm_resource_group" "gallery" {
  name     = "rg-${var.name_prefix}-gallery"
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "build" {
  name     = "rg-${var.name_prefix}-build"
  location = var.location
  tags     = local.tags
}

# ---- Compute Gallery --------------------------------------------------------
resource "azurerm_shared_image_gallery" "this" {
  name                = var.gallery_name
  resource_group_name = azurerm_resource_group.gallery.name
  location            = azurerm_resource_group.gallery.location
  description         = "Golden images published by the image factory"
  tags                = local.tags
}

# Image definitions are created per image request by the build job
# (scripts/ci/lib.sh: ensure_gallery_image_definition), so new images need no
# Terraform change.

# ---- VM landing zone (end-user VMs from the portal) -------------------------
resource "azurerm_resource_group" "vms" {
  name     = "rg-${var.name_prefix}-vms"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "workloads" {
  name                = "vnet-${var.name_prefix}-workloads"
  resource_group_name = azurerm_resource_group.vms.name
  location            = azurerm_resource_group.vms.location
  address_space       = [var.workload_vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "workloads" {
  name                 = "snet-workloads"
  resource_group_name  = azurerm_resource_group.vms.name
  virtual_network_name = azurerm_virtual_network.workloads.name
  address_prefixes     = [cidrsubnet(var.workload_vnet_cidr, 8, 1)]
}

# No NSG on the subnet: each VM's NIC gets its own NSG (terraform/vm/azure),
# because Azure requires inbound traffic to be allowed by *both* subnet and
# NIC NSGs, and per-VM SSH ranges can't be known here.

# Earlier versions created one gallery image definition per OS. Forget them
# without deleting them (they may hold published versions); definitions are
# now created per image request by the build job.
removed {
  from = azurerm_shared_image.os

  lifecycle {
    destroy = false
  }
}

# ---- CI workload identity ---------------------------------------------------
resource "azuread_application" "factory" {
  display_name = "${var.name_prefix}-ci"
  owners       = [data.azurerm_client_config.current.object_id]

  lifecycle {
    precondition {
      condition     = var.github_repository != "" || var.gitlab_project_path != ""
      error_message = "Set github_repository, gitlab_project_path, or both."
    }
  }
}

resource "azuread_service_principal" "factory" {
  client_id = azuread_application.factory.client_id
  owners    = [data.azurerm_client_config.current.object_id]
}

locals {
  github_issuer = "https://token.actions.githubusercontent.com"

  # GitHub subject prefix. Repos created after 2026-07-15 (or opted in) use
  # immutable IDs: repo:<owner>@<owner_id>/<repo>@<repo_id>. Older repos use
  # repo:<owner>/<repo>. Set the IDs to trust the immutable form only.
  github_owner = try(split("/", var.github_repository)[0], "")
  github_repo  = try(split("/", var.github_repository)[1], "")
  github_subject_prefix = (
    var.github_repository_id != ""
    ? "repo:${local.github_owner}@${var.github_owner_id}/${local.github_repo}@${var.github_repository_id}"
    : "repo:${var.github_repository}"
  )

  # Entra ID matches subjects exactly, so each one gets its own credential.
  # GitHub builds run on the branch; promotion jobs run in environments.
  federated_subjects = merge(
    var.github_repository == "" ? {} : {
      "github-${var.github_ref}"         = { issuer = local.github_issuer, subject = "${local.github_subject_prefix}:ref:refs/heads/${var.github_ref}" }
      "github-env-images-azure"          = { issuer = local.github_issuer, subject = "${local.github_subject_prefix}:environment:images-azure" }
      "github-env-images-azure-approval" = { issuer = local.github_issuer, subject = "${local.github_subject_prefix}:environment:images-azure-approval" }
    },
    var.gitlab_project_path == "" ? {} : {
      "gitlab-${var.gitlab_ref}" = { issuer = var.gitlab_url, subject = "project_path:${var.gitlab_project_path}:ref_type:branch:ref:${var.gitlab_ref}" }
    },
  )
}

resource "azuread_application_federated_identity_credential" "ci" {
  for_each = local.federated_subjects

  application_id = azuread_application.factory.id
  display_name   = each.key
  description    = each.value.subject
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = each.value.issuer
  subject        = each.value.subject
}

# Least privilege: Contributor on the factory resource groups only.
resource "azurerm_role_assignment" "build" {
  scope                = azurerm_resource_group.build.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.factory.object_id
}

resource "azurerm_role_assignment" "gallery" {
  scope                = azurerm_resource_group.gallery.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.factory.object_id
}

resource "azurerm_role_assignment" "vms" {
  scope                = azurerm_resource_group.vms.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.factory.object_id
}

# VM state files live next to the factory state (created by the bootstrap
# script). Data-plane access only, no storage keys.
resource "azurerm_role_assignment" "state" {
  count                = var.tf_state_storage_account_id == "" ? 0 : 1
  scope                = var.tf_state_storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.factory.object_id
}
