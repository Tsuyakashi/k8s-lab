# k8s addon for iac-proxmox-lab

New modules/environments only -- nothing here modifies the existing
modules/proxmox-vm, environments/nodes, environments/runner, etc.
Drop these folders into the repo root and they slot in alongside what's there.

## What's included

- `modules/sdn-network/` -- VXLAN zone + VNet (+ optional routed subnet) via
  the SDN resources in bpg/proxmox. Chosen over a plain VLAN zone because it
  only needs UDP connectivity between node IPs, not physical switch VLAN
  trunking -- fits the current bare-proxmox/pve-rog topology behind the
  MT-PON-AT-4 ONT.
- `modules/k8s-cluster/` -- thin for_each wrapper over the existing
  modules/proxmox-vm, fanning a `nodes` map into VMs by role (master/worker)
  with per-role sizing.
- `environments/k8s-network/` -- root module owning the SDN zone/vnet/subnet.
  Deliberately separate state from k8s-nodes, same reasoning as the existing
  nodes/runner split: SDN changes shouldn't trigger VM replacement and vice
  versa.
- `environments/k8s-nodes/` -- root module owning the actual VMs. Reads the
  VNet id from k8s-network via `terraform_remote_state` against the same
  MinIO backend.

## Before first apply

1. `modules/k8s-cluster/main.tf` assumes modules/proxmox-vm's variable names
   (`proxmox_node`, `template_node`, `network_bridge`, `ip_address`, `cores`,
   `memory`, `datastore_id_disk`, `disk_size`, `vm_name`, `tags`). Check these
   against the real module and adjust if any differ.
2. TerraformProv role needs `SDN.Allocate` in addition to the existing
   `SDN.Use` to create the zone itself -- add it in proxmox-init.sh.
3. Both backend.tf files point at the existing MinIO endpoint
   (192.168.100.100:9000, bucket `tfstate`) with new state keys
   (`k8s-network/...`, `k8s-nodes/...`). Adjust the bucket name if it differs
   from what nodes/runner actually use.

## Apply order

```
cd environments/k8s-network && terraform apply
cd environments/k8s-nodes   && terraform apply
```

Then generate an Ansible inventory from `k8s-nodes`' `ips_by_role` output
(same templatefile pattern the nodes/ environment already uses) and run a
kubeadm-ha playbook against it -- keepalived VIP, kubeadm init/join, and CNI
install stay in Ansible, not Terraform, same split already used for
local-path-provisioner in devops-handbook.

## Known limitation

3 masters are spread across only 2 physical hosts (bare-proxmox, pve-rog).
Losing bare-proxmox takes 2 of 3 masters with it and breaks etcd quorum --
this is a demo/reference topology, not real HA, until a third physical host
(or at minimum a lightweight third master/etcd-learner on the Zenbook) is
added.
