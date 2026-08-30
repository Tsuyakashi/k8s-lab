variable "name" {
  description = "VM name in Proxmox and the file_name used for the cloud-init snippet."
  type        = string
}

variable "hostname" {
  description = "Hostname inside the guest (cloud-init). Defaults to var.name."
  type        = string
  default     = null
}

variable "proxmox_node" {
  description = "Target Proxmox node (cluster member, not the VM name)."
  type        = string
}

variable "template_vm_id" {
  description = "VM ID of the golden image this VM is cloned from."
  type        = number
}

variable "tags" {
  description = "Proxmox VM tags (e.g. [\"prod\"], [\"ci\"])."
  type        = list(string)
  default     = []
}

variable "cores" {
  description = "Number of vCPUs."
  type        = number
}

variable "cpu_type" {
  description = "Guest CPU type. 'host' passes through the physical CPU's flags 1:1, which breaks migration between dissimilar nodes."
  type        = string
  default     = "kvm64"
}

variable "memory" {
  description = "Allocated memory, MB."
  type        = number
}

variable "disk_size" {
  description = "System disk size, GB."
  type        = number
  default     = 10
}

variable "datastore_id_disk" {
  description = "Datastore for the VM's disk."
  type        = string
  default     = "local-lvm"
}

variable "datastore_id_snippet" {
  description = "Datastore the cloud-init snippet is uploaded to (must support the 'snippets' content type)."
  type        = string
  default     = "local"
}

variable "mac_address" {
  description = "Pin the network interface's MAC address. null = Proxmox assigns one automatically."
  type        = string
  default     = null
}

variable "ip_config" {
  description = <<-EOT
    Network configuration applied via cloud-init:
      mode    = "static" | "dhcp"
      address = CIDR address, required when mode = "static" (e.g. "10.100.0.11/24")
      gateway = required when mode = "static"
  EOT
  type = object({
    mode    = string
    address = optional(string)
    gateway = optional(string)
  })

  validation {
    condition     = contains(["static", "dhcp"], var.ip_config.mode)
    error_message = "ip_config.mode must be \"static\" or \"dhcp\"."
  }

  validation {
    condition     = var.ip_config.mode != "static" || (var.ip_config.address != null && var.ip_config.gateway != null)
    error_message = "address and gateway are required when ip_config.mode = \"static\"."
  }
}

variable "wait_for_ip_disabled" {
  description = "Don't wait for the guest agent to report an IP (relevant for static addressing — the address is already known upfront)."
  type        = bool
  default     = false
}

variable "vm_ssh_public_key" {
  description = "User's SSH key, injected via cloud-init."
  type        = string
}

variable "ci_ssh_public_key" {
  description = "SSH key for CI/CD access (no passphrase, dedicated to automation, separate from the user key)."
  type        = string
}

variable "extra_packages" {
  description = "Additional apt packages via cloud-init packages: (on top of qemu-guest-agent)."
  type        = list(string)
  default     = []
}

variable "extra_runcmd" {
  description = "Additional shell commands in cloud-init runcmd, run after the base setup."
  type        = list(string)
  default     = []
}

variable "write_files" {
  description = "Extra files via cloud-init write_files (e.g. ~/.terraformrc)."
  type = list(object({
    path        = string
    owner       = optional(string, "root:root")
    permissions = optional(string, "0644")
    content     = string
  }))
  default = []
}

variable "docker_group" {
  description = "Add the ubuntu user to the docker group (only meaningful if docker.io is in extra_packages)."
  type        = bool
  default     = false
}

variable "network_bridge" {
  description = "Bridge or SDN VNet the VM's network interface attaches to."
  type        = string
  default     = "vmbr0"
}

variable "migrate" {
  description = "Use the live migration API when node_name changes, instead of destroy/recreate."
  type        = bool
  default     = false
}

variable "stop_on_destroy" {
  description = "Force-stop instead of a graceful ACPI/agent shutdown on destroy. true is safer when the guest agent might not be running (e.g. VM never fully booted)."
  type        = bool
  default     = true
}

variable "template_node" {
  description = "Node where the golden image physically lives, if different from var.proxmox_node. Defaults to var.proxmox_node (same-node clone)."
  type        = string
  default     = null
}
