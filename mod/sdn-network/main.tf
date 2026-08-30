/**
 * mod/sdn-network
 *
 * Declares a Proxmox SDN VXLAN zone + VNet (+ optional routed subnet) to be
 * used as an isolated overlay segment for a group of VMs (e.g. a k8s
 * control-plane).
 *
 * VXLAN chosen over a plain VLAN zone because it only requires UDP
 * connectivity between node IPs (the underlay) -- no physical switch VLAN
 * trunking needed. This matters when the physical LAN doesn't guarantee a
 * managed switch tagging the same VLAN between every Proxmox node.
 *
 * Two-step SDN apply (applier + finalizer) is a known provider requirement:
 * SDN changes are staged, then must be explicitly applied cluster-wide.
 * See: https://github.com/bpg/terraform-provider-proxmox/issues/2212
 */

resource "proxmox_sdn_zone_vxlan" "this" {
  id    = var.zone_id
  nodes = var.nodes
  peers = var.peers
  mtu   = var.mtu
  ipam  = "pve"
}

resource "proxmox_sdn_vnet" "this" {
  id   = var.vnet_id
  zone = proxmox_sdn_zone_vxlan.this.id
  tag  = var.vni_tag

  depends_on = [proxmox_sdn_applier.finalizer]
}

# Optional routed subnet with a gateway -- only create it if the caller wants
# host-level L3 (e.g. so the segment can reach a state backend/secrets store
# on the LAN via NAT).
resource "proxmox_sdn_subnet" "this" {
  count = var.subnet_cidr != null ? 1 : 0

  vnet    = proxmox_sdn_vnet.this.id
  cidr    = var.subnet_cidr
  gateway = var.subnet_gateway
  snat    = var.subnet_snat

  depends_on = [proxmox_sdn_vnet.this]
}

resource "proxmox_sdn_applier" "finalizer" {}

resource "proxmox_sdn_applier" "applier" {
  depends_on = [
    proxmox_sdn_vnet.this,
    proxmox_sdn_subnet.this,
  ]

  lifecycle {
    replace_triggered_by = [
      proxmox_sdn_vnet.this,
    ]
  }
}
