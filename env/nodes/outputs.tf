output "node_ids" {
  description = "Proxmox VM ID per node."
  value       = { for k, m in module.node : k => m.vm_id }
}

output "ips_by_role" {
  description = "Map of role => list of {name, ip}. Feed into an Ansible inventory templatefile."
  value = {
    for role in distinct([for n in var.nodes : n.role]) :
    role => [
      for name, n in var.nodes : { name = name, ip = split("/", n.ip_address)[0] }
      if n.role == role
    ]
  }
}

output "all_ips" {
  description = "Static node IPs (from var.nodes — known upfront, no need to query the guest agent)."
  value       = { for k, v in var.nodes : k => split("/", v.ip_address)[0] }
}
