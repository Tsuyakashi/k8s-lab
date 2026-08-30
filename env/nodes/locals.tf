data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    endpoints = {
      s3 = "http://192.168.100.100:9000"
    }
    bucket                      = "k8s-lab-tfstate"
    key                         = "network/terraform.tfstate"
    region                      = "us-east-1"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}

locals {
  # Same principle as every other environment in the parent project:
  # proxmox_node resolves both the endpoint (used only for providers.tf)
  # and the golden image a VM clones from. Kept here rather than in
  # mod/pve-vm on purpose — the module shouldn't know that "bare-pve" = 9000
  # and "pve-rog" = 9001; that's a fact about this specific cluster, not
  # general VM-provisioning logic.
  proxmox_nodes = {
    "bare-pve" = {
      endpoint       = "https://192.168.100.30:8006/"
      template_vm_id = 9000
    }
    "pve-rog" = {
      endpoint       = "https://192.168.100.20:8006/"
      template_vm_id = 9001
    }
  }

  proxmox_endpoint = local.proxmox_nodes[var.proxmox_node].endpoint

  # Kept separate from env/network's own state on purpose — this
  # environment should never be able to trigger a re-apply of the SDN
  # zone/vnet, and vice versa, same reasoning as splitting
  # environments/nodes from environments/runner in the parent project.
  network_bridge = data.terraform_remote_state.network.outputs.vnet_id

  # This used to be a separate mod/k8s-cluster module that did exactly this
  # merge + for_each over mod/pve-vm under the hood — an extra layer for a
  # single for_each, removed. role_specs cleanly handles what differs per
  # role (cores/memory/disk); template_vm_id resolves per-node from each
  # entry's own proxmox_node (never from var.proxmox_node) — a cross-node
  # clone is structurally impossible, the same protection the parent
  # project added after the minecraft-node/immich-node incidents.
  nodes_resolved = {
    for name, n in var.nodes : name => merge(
      var.role_specs[n.role],
      n,
      {
        template_vm_id = local.proxmox_nodes[n.proxmox_node].template_vm_id
      }
    )
  }
}
