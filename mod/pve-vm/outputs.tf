output "vm_id" {
  description = "Proxmox VM ID of the created VM."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "VM name (= var.name)."
  value       = proxmox_virtual_environment_vm.this.name
}

output "ipv4_addresses" {
  description = <<-EOT
    Raw interface -> [addresses] map as reported by the QEMU guest agent.
    Empty until the agent comes up and reports in (mostly relevant for
    dhcp mode — with static IP the caller already knows the address
    upfront from var.ip_config.address).
  EOT
  value       = proxmox_virtual_environment_vm.this.ipv4_addresses
}
