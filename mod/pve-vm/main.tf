/**
 * mod/pve-vm
 *
 * Single unit of provisioning: one VM cloned from a golden image, with a
 * cloud-init snippet (user + guest agent + hostname) and either a static
 * or dhcp address on its primary NIC, plus an optional second NIC
 * (var.second_network — see variables.tf for why ci-bootstrap uses it).
 *
 * The module is self-contained and not tied to any specific project: no
 * backend{}, no provider "proxmox" (endpoint/token/ssh is the calling root
 * module's job), and no assumptions about any particular physical
 * network/lab (no hardcoded retry-ping to a specific IP, etc.) — if
 * something like that is needed, it goes through var.extra_runcmd from the
 * calling root module.
 */

locals {
  # Guest hostname defaults to the resource name, overridable.
  hostname = coalesce(var.hostname, var.name)
}

resource "proxmox_virtual_environment_file" "cloud_init_user_data" {
  content_type = "snippets"
  datastore_id = var.datastore_id_snippet
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/templates/user-data.yml.tpl", {
      vm_ssh_public_key = var.vm_ssh_public_key
      ci_ssh_public_key = var.ci_ssh_public_key
      hostname          = local.hostname
      extra_packages    = var.extra_packages
      extra_runcmd      = var.extra_runcmd
      write_files       = var.write_files
      docker_group      = var.docker_group
    })
    file_name = "${var.name}-user-data.yml"
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.proxmox_node
  tags      = var.tags

  migrate = var.migrate

  # agent.enabled = true below switches graceful shutdown from ACPI to
  # qemu-guest-agent -- if the agent never comes up (or hangs), destroy
  # waits out the full timeout while holding a lock on the VM.
  # stop_on_destroy = true forces a hard stop instead of a graceful
  # shutdown attempt.
  stop_on_destroy = var.stop_on_destroy

  clone {
    vm_id     = var.template_vm_id
    node_name = coalesce(var.template_node, var.proxmox_node)
    full      = true
  }

  agent {
    enabled = true

    wait_for_ip {
      disabled = var.wait_for_ip_disabled
    }
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.datastore_id_disk
    interface    = "scsi0"
    size         = var.disk_size
  }

  # Primary NIC — always present.
  network_device {
    bridge      = var.network_bridge
    mac_address = var.mac_address
  }

  # Optional second NIC (see var.second_network). MUST stay declared after
  # the primary network_device block above — the provider pairs
  # network_device/ip_config blocks up by declaration order, not by name.
  dynamic "network_device" {
    for_each = var.second_network != null ? [var.second_network] : []
    content {
      bridge = network_device.value.bridge
    }
  }

  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
  }

  initialization {
    datastore_id = var.datastore_id_disk
    dns {
      servers = ["1.1.1.1", "8.8.8.8"]
    }

    # ip_config for the primary NIC — always present, matches
    # network_device #1 above by order.
    ip_config {
      ipv4 {
        address = var.ip_config.mode == "static" ? var.ip_config.address : "dhcp"
        gateway = var.ip_config.mode == "static" ? var.ip_config.gateway : null
      }
    }

    # ip_config for the optional second NIC — MUST stay declared after the
    # primary ip_config block above, matches network_device #2 by order.
    dynamic "ip_config" {
      for_each = var.second_network != null ? [var.second_network.ip_config] : []
      content {
        ipv4 {
          address = ip_config.value.mode == "static" ? ip_config.value.address : "dhcp"
          gateway = ip_config.value.mode == "static" ? ip_config.value.gateway : null
        }
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init_user_data.id
  }

  operating_system {
    type = "l26"
  }
}
