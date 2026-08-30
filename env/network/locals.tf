locals {
  # nodes/peers for sdn_zone_vxlan must be in the same order — node_names[i]
  # corresponds to node_ips[i]. Explicit for-loop instead of values(), so
  # the order is guaranteed to match node_names rather than relying on
  # keys()/values() staying in sync across Terraform versions.
  proxmox_nodes = {
    "bare-pve" = {
      endpoint = "https://192.168.100.30:8006/"
      ip       = "192.168.100.30"
    }
    "pve-rog" = {
      endpoint = "https://192.168.100.20:8006/"
      ip       = "192.168.100.20"
    }
  }

  proxmox_endpoint = local.proxmox_nodes[var.proxmox_node].endpoint

  # nodes/peers for sdn_zone_vxlan must be in the same order — node_names[i]
  # corresponds to node_ips[i]. Explicit for-loop instead of values(), so
  # the order is guaranteed to match node_names rather than relying on
  # keys()/values() staying in sync across Terraform versions.
  node_names = keys(local.proxmox_nodes)
  node_ips   = [for n in local.node_names : local.proxmox_nodes[n].ip]
}
