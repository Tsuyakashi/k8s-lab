variable "zone_id" {
  description = "SDN zone identifier. Proxmox SDN rule: <= 8 chars, lowercase, no dashes."
  type        = string
}

variable "vnet_id" {
  description = "SDN VNet identifier. Same naming rule as zone_id."
  type        = string
}

variable "vni_tag" {
  description = "VXLAN VNI for this VNet's own L2 domain within the EVPN zone. Distinct from vrf_vxlan (the zone's dedicated routing-interconnect VNI) — this one is per-VNet. Must be unique cluster-wide, not equal to vrf_vxlan or any other VNet's tag."
  type        = number
}

variable "nodes" {
  description = "Proxmox node names the zone/VNet should be deployed on (e.g. [\"bare-pve\", \"pve-rog\"])."
  type        = list(string)
}

variable "peers" {
  description = "Underlay IPs of the nodes above. Used as BGP peer addresses for the EVPN controller's iBGP mesh (see mod/sdn-network's controller resource) — not VXLAN tunnel peers, EVPN doesn't use static VXLAN peering the way a plain vxlan zone does."
  type        = list(string)
}

variable "mtu" {
  description = "MTU for the EVPN zone. Should be 50 bytes below the underlying physical interface MTU (VXLAN encapsulation overhead)."
  type        = number
  default     = 1450
}

variable "controller_id" {
  description = "EVPN controller identifier. Same naming rule as zone_id: <= 8 chars, lowercase, no dashes."
  type        = string
}

variable "controller_asn" {
  description = "Private ASN for the EVPN controller's iBGP mesh (64512-65534 range recommended). Must be identical across every controller in this cluster."
  type        = number
}

variable "vrf_vxlan" {
  description = "VRF VXLAN-ID for the EVPN zone's routing interconnect between VNets. Must differ from vni_tag (the VNet's own L2-domain VNI) and from any other zone's VNI, cluster-wide."
  type        = number
}

variable "exit_nodes" {
  description = "Nodes that can act as SNAT/routing exit points for this EVPN zone's subnet traffic."
  type        = list(string)
}

variable "primary_exit_node" {
  description = "The exit node that actually owns the gateway/SNAT at any given time (must be one of exit_nodes). Only this node materializes the subnet gateway IP; failover to another exit node is a manual/HA concern, not automatic."
  type        = string
}

variable "subnet_cidr" {
  description = "Optional routed subnet CIDR for this VNet (e.g. \"10.100.0.0/24\"). Leave null to skip creating a subnet (pure L2 segment)."
  type        = string
  default     = null
}

variable "subnet_gateway" {
  description = "Gateway IP for subnet_cidr. Required if subnet_cidr is set."
  type        = string
  default     = null
}

variable "subnet_snat" {
  description = "Enable Source-NAT (masquerade) on this subnet's gateway, so guests reach the internet through the exit node's own uplink. Maps directly to Proxmox SDN's 'snat' checkbox / subnets.cfg 'snat 1'. Only meaningful when subnet_cidr is set. Unlike a plain vxlan zone, this actually materializes for an EVPN zone via the primary_exit_node."
  type        = bool
  default     = false
}
