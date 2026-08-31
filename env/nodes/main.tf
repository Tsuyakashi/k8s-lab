# env/nodes
#
# Root module for the k8s control-plane + worker nodes. Own state
# (S3/MinIO), own lifecycle, separate from env/network — apply here never
# triggers an SDN zone/vnet re-apply, and vice versa. The VNet id is read
# via terraform_remote_state (see locals.tf).
#
# for_each directly over mod/pve-vm, no intermediate "cluster" module —
# the for_each itself and role-based sizing (cores/memory/disk per role)
# aren't complex enough to warrant a separate module; it all lives in
# locals.nodes_resolved.

module "node" {
  source = "../../mod/pve-vm"

  for_each = local.nodes_resolved

  name           = each.key
  proxmox_node   = each.value.proxmox_node
  template_node  = each.value.proxmox_node # clone from the local golden image on the same node, not across the cluster
  template_vm_id = each.value.template_vm_id
  tags           = concat(["k8s", each.value.role], each.value.extra_tags)

  cores             = each.value.cores
  memory            = each.value.memory
  disk_size         = each.value.disk_size
  datastore_id_disk = each.value.datastore_id_disk

  mac_address    = each.value.mac_address
  network_bridge = local.network_bridge

  ip_config = {
    mode    = "static"
    address = each.value.ip_address
    gateway = each.value.gateway
  }

  # Second NIC on the LAN — only set for ci-bootstrap (see variables.tf's
  # lan_ip/lan_gateway doc). Masters/workers stay single-NIC on k8scp.
  second_network = each.value.lan_ip != null ? {
    bridge = "vmbr0"
    ip_config = {
      mode    = "static"
      address = each.value.lan_ip
      gateway = each.value.lan_gateway
    }
  } : null

  # IP is known upfront (static) — no point waiting on the guest agent during apply
  wait_for_ip_disabled = true

  vm_ssh_public_key = var.vm_ssh_public_key
  ci_ssh_public_key = var.ci_ssh_public_key
}
