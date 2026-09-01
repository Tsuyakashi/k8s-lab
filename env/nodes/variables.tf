variable "proxmox_api_token" {
  description = "Proxmox API token, format: user@realm!token-name=uuid-secret"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (self-signed cert)"
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Which cluster node's API this apply talks to. Doesn't affect where any k8s node itself is placed (see nodes[].proxmox_node) — only the provider's connection endpoint."
  type        = string
  default     = "bare-pve"
}

variable "vm_ssh_public_key" {
  description = "SSH public key to inject into every node via cloud-init"
  type        = string
}

variable "ci_ssh_public_key" {
  description = "Public key for CI/CD deploy access"
  type        = string
}

variable "include_bootstrap" {
  description = <<-EOT
    Whether module.node["ci-bootstrap"] participates in this apply.
    Defaults to false so a plain `terraform apply` never creates, updates,
    or touches the ephemeral bootstrap node — only scripts/bootstrap-run.sh
    manages it, passing `-var include_bootstrap=true` together with its own
    `-target='module.node["ci-bootstrap"]'`. Without this, ci-bootstrap is
    just another key in var.nodes and a plain apply would stand it up as a
    permanent VM, defeating the whole "closed box" premise (see README).
  EOT
  type        = bool
  default     = false
}

variable "role_specs" {
  description = "Per-role sizing. Keys must cover every role used in var.nodes."
  type = map(object({
    cores             = number
    memory            = number
    disk_size         = number
    datastore_id_disk = optional(string, "local-lvm")
  }))
  default = {
    master = {
      cores     = 4
      memory    = 4096
      disk_size = 40
    }
    worker = {
      cores     = 2
      memory    = 2048
      disk_size = 20
    }
    # Ephemeral SSH jump box into the k8scp EVPN subnet (10.100.0.0/24) —
    # created just before an ansible run (see scripts/bootstrap-run.sh) and
    # destroyed right after, "закрытый ящик" doesn't get a standing
    # tunnel/route from the LAN. No swap/heavy workload runs on it, hence
    # the minimal spec.
    bootstrap = {
      cores     = 1
      memory    = 512
      disk_size = 10
    }
  }
}

variable "nodes" {
  description = <<-EOT
    k8s cluster topology. 3 masters spread across 2 physical hosts: losing
    bare-pve takes down 2/3 masters and breaks quorum — an accepted
    limitation of a 2-node cluster, not full HA. See README.md and the
    comment in mod/sdn-network.

    template_vm_id is deliberately NOT a field of this object — it's
    resolved in locals.tf from each entry's own proxmox_node, so a
    cross-node clone is structurally impossible.

    "ci-bootstrap" is not a cluster member — it's the ephemeral jump box
    scripts/bootstrap-run.sh applies/destroys around each ansible run. Kept
    in the same var.nodes map (not a separate environment) so it shares
    ips_by_role/all_ips output and the same nodes_resolved merge logic as
    every real node — but see var.include_bootstrap above: it's filtered
    out of nodes_resolved (and therefore out of any plain apply) unless
    explicitly included.

    lan_ip/lan_gateway: only meaningful for "ci-bootstrap". Gives it a
    SECOND nic on the LAN (vmbr0), in addition to its primary nic on
    k8scp — an operator's laptop has no route into 10.100.0.0/24, so this
    is what scripts/bootstrap-run.sh/generate-inventory.sh actually SSH to.
    See mod/pve-vm's second_network variable for the mechanics. null on
    every other node (masters/workers only ever need the k8scp side).
  EOT
  type = map(object({
    role         = string # a key in var.role_specs, e.g. "master"/"worker"/"bootstrap"
    ip_address   = string # CIDR, e.g. "10.100.0.11/24" — primary NIC, always on k8scp
    gateway      = string
    proxmox_node = string
    mac_address  = optional(string)
    extra_tags   = optional(list(string), [])
    lan_ip       = optional(string) # CIDR, e.g. "192.168.100.99/24" — second NIC, LAN
    lan_gateway  = optional(string)
  }))
  default = {
    "control-plane-1" = {
      role         = "master"
      ip_address   = "10.100.0.11/24"
      gateway      = "10.100.0.1"
      proxmox_node = "bare-pve"
    }
    "control-plane-2" = {
      role         = "master"
      ip_address   = "10.100.0.12/24"
      gateway      = "10.100.0.1"
      proxmox_node = "pve-rog"
    }
    "control-plane-3" = {
      role         = "master"
      ip_address   = "10.100.0.13/24"
      gateway      = "10.100.0.1"
      proxmox_node = "bare-pve"
    }
    "worker-1" = {
      role         = "worker"
      ip_address   = "10.100.0.21/24"
      gateway      = "10.100.0.1"
      proxmox_node = "pve-rog"
    }
    "worker-2" = {
      role         = "worker"
      ip_address   = "10.100.0.22/24"
      gateway      = "10.100.0.1"
      proxmox_node = "pve-rog"
    }
    "ci-bootstrap" = {
      role         = "bootstrap"
      ip_address   = "10.100.0.99/24"
      gateway      = "10.100.0.1"
      proxmox_node = "bare-pve"
      lan_ip       = "192.168.100.99/24"
      lan_gateway  = "192.168.100.1"
    }
  }
}
