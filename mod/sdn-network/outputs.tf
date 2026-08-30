output "vnet_id" {
  description = "The VNet identifier -- pass this as network_bridge to mod/pve-vm for any VM that should sit on this segment."
  value       = proxmox_sdn_vnet.this.id
}

output "zone_id" {
  description = "The SDN zone identifier."
  value       = proxmox_sdn_zone_vxlan.this.id
}

output "subnet_gateway" {
  description = "Gateway IP of the created subnet, if any (null if subnet_cidr was not set)."
  value       = var.subnet_cidr != null ? var.subnet_gateway : null
}
