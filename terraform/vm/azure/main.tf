# =============================================================================
# One end-user VM from an approved golden image.
#
# Driven by vms/<name>.yaml through the vm-provision workflow:
#   scripts/portal/vm_tfvars.py turns the request into request.auto.tfvars.json;
#   platform settings (subnet, resource group, gallery) come from TF_VAR_*
#   environment variables set from the repository variables.
# State: one file per VM (vms/<name>.tfstate) in the factory state account.
# =============================================================================

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

locals {
  tags = {
    ManagedBy    = "image-factory"
    Owner        = var.owner
    Environment  = var.environment
    RequestedBy  = var.requested_by
    Image        = var.image
    ImageVersion = data.azurerm_shared_image_version.image.name
    Request      = "vms/${var.name}.yaml"
  }
}

# "latest" resolves to the newest version not excluded from latest, which
# is the newest *promoted* image (candidates are excluded until they pass
# the scan).
data "azurerm_shared_image_version" "image" {
  name                = var.image_version
  image_name          = var.image
  gallery_name        = var.gallery_name
  resource_group_name = var.gallery_resource_group
}

resource "azurerm_public_ip" "this" {
  count               = var.public_ip ? 1 : 0
  name                = "pip-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.region
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_security_group" "ssh" {
  count               = var.public_ip ? 1 : 0
  name                = "nsg-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.region
  tags                = local.tags

  security_rule {
    name                       = "ssh-from-allowed-range"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "this" {
  name                = "nic-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.region
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.public_ip ? azurerm_public_ip.this[0].id : null
  }
}

resource "azurerm_network_interface_security_group_association" "ssh" {
  count                     = var.public_ip ? 1 : 0
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.ssh[0].id
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = var.name
  computer_name                   = var.name
  resource_group_name             = var.resource_group_name
  location                        = var.region
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.this.id]
  source_image_id                 = data.azurerm_shared_image_version.image.id
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "osdisk-${var.name}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_gb
  }

  identity {
    type = "SystemAssigned"
  }

  boot_diagnostics {} # managed storage account

  lifecycle {
    # A newer golden image shouldn't silently rebuild a running VM. Pin
    # image_version or recreate the VM deliberately to move to a new image.
    ignore_changes = [source_image_id]
  }
}
