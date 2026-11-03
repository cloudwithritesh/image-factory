output "gallery_id" {
  value = azurerm_shared_image_gallery.this.id
}

output "image_definitions" {
  value = { for k, v in azurerm_shared_image.os : k => v.id }
}

output "ci_variables" {
  description = "Set these as GitHub repository variables or GitLab CI/CD variables (same names)"
  value = {
    AZURE_CLIENT_ID                      = azuread_application.factory.client_id
    AZURE_TENANT_ID                      = data.azurerm_client_config.current.tenant_id
    PKR_VAR_azure_subscription_id        = var.subscription_id
    PKR_VAR_azure_build_resource_group   = azurerm_resource_group.build.name
    PKR_VAR_azure_gallery_resource_group = azurerm_resource_group.gallery.name
    PKR_VAR_azure_gallery_name           = azurerm_shared_image_gallery.this.name
    PKR_VAR_azure_gallery_location       = azurerm_shared_image_gallery.this.location
  }
}
