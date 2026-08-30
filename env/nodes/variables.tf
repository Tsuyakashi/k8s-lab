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
  EOT
  type = map(object({
    role         = string # a key in var.role_specs, e.g. "master"/"worker"
    ip_address   = string # CIDR, e.g. "10.100.0.11/24"
    gateway      = string
    proxmox_node = string
    mac_address  = optional(string)
    extra_tags   = optional(list(string), [])
  }))
  default = {
    "cp-1" = {
      role         = "master"
      ip_address   = "10.100.0.11/24"
      gateway      = "10.100.0.1"
      proxmox_node = "bare-pve"
    }
    "cp-2" = {
      role         = "master"
      ip_address   = "10.100.0.12/24"
      gateway      = "10.100.0.1"
      proxmox_node = "pve-rog"
    }
    "cp-3" = {
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
  }
}
