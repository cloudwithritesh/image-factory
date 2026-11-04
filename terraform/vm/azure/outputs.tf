output "vm_id" {
  value = azurerm_linux_virtual_machine.this.id
}

output "private_ip" {
  value = azurerm_network_interface.this.private_ip_address
}

output "public_ip" {
  value = var.public_ip ? azurerm_public_ip.this[0].ip_address : ""
}

output "image_version" {
  description = "Gallery image version the VM was built from"
  value       = data.azurerm_shared_image_version.image.name
}

output "ssh" {
  value = "ssh ${var.admin_username}@${var.public_ip ? azurerm_public_ip.this[0].ip_address : azurerm_network_interface.this.private_ip_address}"
}
