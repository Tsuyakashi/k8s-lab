output "node_ids" {
  description = "Proxmox VM ID per node."
  value       = { for k, m in module.node : k => m.vm_id }
}

output "ips_by_role" {
  description = "Map of role => list of {name, ip}. ip is the PRIMARY (k8scp-side) address for every role, including bootstrap — see bootstrap_lan_ip below for its LAN-side address."
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

output "bootstrap_lan_ip" {
  description = <<-EOT
    LAN-facing address of ci-bootstrap's second NIC (see mod/pve-vm's
    second_network / env/nodes' nodes[].lan_ip). This — not
    ips_by_role.bootstrap[0].ip, which is the k8scp-side address — is what
    scripts/bootstrap-run.sh and scripts/generate-inventory.sh actually
    SSH to, since an operator's laptop has no route into 10.100.0.0/24.
    Empty string if ci-bootstrap has no lan_ip configured, or wasn't part
    of this apply (var.include_bootstrap=false).
  EOT
  value       = try(split("/", var.nodes["ci-bootstrap"].lan_ip)[0], "")
}
