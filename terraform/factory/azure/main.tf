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
  required_version = ">= 1.6.0"
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

  # One gallery image definition per OS that has an Azure target, read from
  # the same catalog the request validator uses.
  os_catalog = yamldecode(file("${path.module}/../../../catalog/os.yaml"))
  azure_images = {
    for key, os in local.os_catalog : os.targets.azure.gallery_image_definition => {
      os_key     = key
      os_type    = os.family == "windows" ? "Windows" : "Linux"
      generation = try(os.targets.azure.hyper_v_generation, "V2")
      display    = os.display_name
    } if can(os.targets.azure)
  }
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

resource "azurerm_shared_image" "os" {
  for_each = local.azure_images

  name                = each.key
  gallery_name        = azurerm_shared_image_gallery.this.name
  resource_group_name = azurerm_resource_group.gallery.name
  location            = azurerm_resource_group.gallery.location
  os_type             = each.value.os_type
  hyper_v_generation  = each.value.generation
  description         = each.value.display

  identifier {
    publisher = var.image_publisher
    offer     = each.value.os_key
    sku       = "golden"
  }

  tags = merge(local.tags, { OsKey = each.value.os_key })
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

  # Entra ID matches subjects exactly, so each one gets its own credential.
  # GitHub builds run on the branch; promotion jobs run in environments.
  federated_subjects = merge(
    var.github_repository == "" ? {} : {
      "github-${var.github_ref}"         = { issuer = local.github_issuer, subject = "repo:${var.github_repository}:ref:refs/heads/${var.github_ref}" }
      "github-env-images-azure"          = { issuer = local.github_issuer, subject = "repo:${var.github_repository}:environment:images-azure" }
      "github-env-images-azure-approval" = { issuer = local.github_issuer, subject = "repo:${var.github_repository}:environment:images-azure-approval" }
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

# Least privilege: Contributor on the two factory resource groups only.
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
