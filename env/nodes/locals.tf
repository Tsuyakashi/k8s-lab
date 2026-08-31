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

  # "ci-bootstrap" is filtered OUT of the default for_each set unless
  # var.include_bootstrap is explicitly true. Without this, a plain
  # `terraform apply` (no -target) creates every key in var.nodes,
  # including ci-bootstrap — which defeats the entire point of it being
  # an ephemeral, script-managed jump box (see scripts/bootstrap-run.sh
  # and README "The closed box"). scripts/bootstrap-run.sh is the only
  # caller that ever passes -var include_bootstrap=true, alongside its
  # own -target on that one module instance. A side effect worth knowing:
  # if ci-bootstrap is ever left lingering in state (e.g. a previous plain
  # apply created it before this filter existed), the next plain apply
  # will show it as "to destroy" — that's intentional self-cleanup, not a
  # bug.
  nodes_resolved = {
    for name, n in var.nodes : name => merge(
      var.role_specs[n.role],
      n,
      {
        template_vm_id = local.proxmox_nodes[n.proxmox_node].template_vm_id
      }
    )
    if name != "ci-bootstrap" || var.include_bootstrap
  }
}
