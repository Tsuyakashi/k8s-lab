variable "zone_id" {
  description = "SDN zone identifier. Proxmox SDN rule: <= 8 chars, lowercase, no dashes."
  type        = string
}

variable "vnet_id" {
  description = "SDN VNet identifier. Same naming rule as zone_id."
  type        = string
}

variable "nodes" {
  description = "Proxmox node names the zone/VNet should be deployed on (e.g. [\"bare-pve\", \"pve-rog\"])."
  type        = list(string)
}

variable "peers" {
  description = "Underlay IPs of the nodes above, used for the VXLAN tunnel endpoints. Order should match `nodes`."
  type        = list(string)
}

variable "vni_tag" {
  description = "VXLAN Network Identifier (VNI) for this VNet's segment."
  type        = number
}

variable "mtu" {
  description = "MTU for the VXLAN zone. Should be 50 bytes below the underlying physical interface MTU (VXLAN encapsulation overhead)."
  type        = number
  default     = 1450
}

variable "ipam" {
  description = "IPAM plugin backing this zone. 'pve' is the built-in one (no external dependency) — required for gateway/snat from subnets.cfg to actually materialize into /etc/network/interfaces.d/sdn."
  type        = string
  default     = "pve"
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
  description = "Enable Source-NAT (masquerade) on this subnet's gateway, so guests reach the internet through the node's own uplink. Maps directly to Proxmox SDN's 'snat' checkbox / subnets.cfg 'snat 1'. Only meaningful when subnet_cidr is set."
  type        = bool
  default     = false
}
