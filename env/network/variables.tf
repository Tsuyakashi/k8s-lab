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
  description = "Which cluster node's API this apply talks to. Only affects the connection endpoint — SDN zone/vnet config is cluster-wide (pmxcfs), unrelated to placement."
  type        = string
  default     = "bare-pve"
}
