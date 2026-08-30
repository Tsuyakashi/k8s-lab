/**
 * mod/sdn-network
 *
 * EVPN zone + VNet (+ optional routed subnet with SNAT) — a routable L3
 * segment spanning multiple physical nodes.
 *
 * EVPN instead of VXLAN: a stretched VXLAN zone can't materialize a
 * subnet gateway/SNAT onto any node's interface (would put the same
 * gateway IP on every node in the L2 segment — a conflict). EVPN solves
 * this via BGP-learned routes + an explicit exit-node concept, at the
 * cost of running FRR/BGP (proxmox_sdn_controller_evpn — one iBGP mesh
 * over var.peers).
 */

resource "proxmox_sdn_controller_evpn" "this" {
  id    = var.controller_id
  asn   = var.controller_asn
  peers = var.peers
}

resource "proxmox_sdn_zone_evpn" "this" {
  id         = var.zone_id
  nodes      = var.nodes
  controller = proxmox_sdn_controller_evpn.this.id
  vrf_vxlan  = var.vrf_vxlan
  mtu        = var.mtu
  ipam       = "pve"

  exit_nodes        = var.exit_nodes
  primary_exit_node = var.primary_exit_node
  advertise_subnets = true

  depends_on = [proxmox_sdn_controller_evpn.this]
}

resource "proxmox_sdn_vnet" "this" {
  id   = var.vnet_id
  zone = proxmox_sdn_zone_evpn.this.id
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
    proxmox_sdn_controller_evpn.this,
    proxmox_sdn_zone_evpn.this,
    proxmox_sdn_vnet.this,
    proxmox_sdn_subnet.this,
  ]

  lifecycle {
    replace_triggered_by = [
      proxmox_sdn_zone_evpn.this,
      proxmox_sdn_vnet.this,
      proxmox_sdn_subnet.this,
    ]
  }
}
