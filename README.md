# k8s-lab

Terraform + Ansible infra for Kubernetes control-plane + worker nodes on
Proxmox, built on the same principles (`mod/` + `env/`, S3/MinIO backend,
cloud-init via `bpg/proxmox`) as the parent project — but this is a
**separate, self-contained repository**, not an add-on on top of it.
Modules aren't imported from anywhere external and don't depend on files
from another repo.

## What's NOT part of this project

Everything related to the initial setup of the Proxmox cluster itself is
already done in a separate project (`iac-proxmox-lab`) and isn't duplicated
here:

- Installing Proxmox VE, clustering the nodes, the QDevice arbiter
- The `TerraformProv` role/token for API access (`proxmox-init.sh`)
- Golden images (VM 9000/9001) — this project assumes they already exist
  on both nodes
- MinIO (S3-compatible state backend) and Vault (secrets storage) — this
  project just **uses** them, it doesn't stand them up itself. Vault is
  not optional here (see [Secrets & Vault](#secrets--vault) below) — the
  whole bootstrap flow reads/writes through it.
- `scripts/vault-apply-wrapper.sh` and the whole Vault flow — if it's
  already set up in the parent project, just source it here too: secrets
  get picked up the same way (`TF_VAR_proxmox_api_token`,
  `TF_VAR_vm_ssh_public_key`, `TF_VAR_ci_ssh_public_key`). Without it —
  `terraform.tfvars` in each `env/*`.

If you don't have a separate `iac-proxmox-lab` (or similar), every point
above needs to be solved on your own infra first — this repository starts
from an already-running Proxmox cluster with a golden image on each node.

**The one additional requirement for the TerraformProv role:** it needs
`SDN.Allocate` in addition to the already-present `SDN.Use` — `SDN.Use` is
enough for a VNet/subnet, but not for creating the SDN zone itself.

## Layout

```
k8s-lab/
├── mod/
│   ├── pve-vm/                  # the only primitive module: one VM,
│   │                             #   cloned from a golden image + cloud-init
│   └── sdn-network/              # SDN zone + VNet (+opt. subnet) on top of
│                                  #   bpg/proxmox
├── env/
│   ├── network/                  # root module — SDN zone/vnet only
│   └── nodes/                    # root module — masters/workers +
│                                  #   the ephemeral bootstrap node
│                                  #   (for_each directly over mod/pve-vm,
│                                  #   no intermediate "cluster" module —
│                                  #   role sizing and per-node golden-image
│                                  #   resolution live in env/nodes/locals.tf)
├── ansible/                      # kubeadm-HA playbook, run against the
│                                  #   subnet through the bootstrap node
└── scripts/
    ├── bootstrap-run.sh          # apply bootstrap -> playbook -> destroy
    ├── generate-inventory.sh     # terraform output -> Ansible inventory
    ├── vault-attach-k8scp.sh     # one-time: give Vault a native
    │                             #   presence on the k8scp subnet
    └── frr-evpn-safety.sh        # EVPN default-route leak fix, see
                                  #   docs/troubleshooting.md
```

**Why there's only one VM module, not `pve-vm` plus a separate
`k8s-cluster` wrapper on top.** The only thing the "cluster" layer added
was a `for_each` over `var.nodes` and per-role sizing
(`role_specs[role].cores` etc.). That's not standalone logic worth
encapsulating separately — it's exactly the same use of `pve-vm` that's
already the norm in the parent project (`environments/nodes`,
`environments/poly-nodes`, etc. all call `modules/proxmox-vm` via
`for_each` directly in their own `main.tf`, no wrapper). The wrapper added
indirection with no payoff and meant keeping near-identical `variables.tf`
in two places in sync. `pve-vm` stays the one reusable primitive — "one
VM"; anything about "several VMs with different roles" is the calling
`env/*`'s job.

**Why `sdn-network` is a separate `env`, not part of `env/nodes`.** SDN
zone/vnet changes are far less frequent than the VMs themselves. Keeping
them in one state means any vnet change would trigger a replace on the VM
resources through the same blast radius that, in the parent project, once
took down the CI runner (see its README, "Two independent root modules, on
purpose") — the same lesson, applied here upfront instead of after an
incident.

## Network choice: EVPN, not a plain VXLAN zone

`mod/sdn-network` uses `sdn_zone_evpn` rather than `sdn_zone_vxlan`. A
stretched VXLAN zone can't materialize a subnet gateway/SNAT on any node's
interface — putting the same gateway IP on every node in the L2 segment
would conflict. EVPN solves this via BGP (FRR, one iBGP mesh over the
node IPs) plus an explicit exit-node/primary-exit-node concept, so exactly
one node (`primary_exit_node`) owns the gateway/SNAT for the segment.
Cost: FRR/BGP must be running on every node in `var.nodes`.

## The "closed box": no standing access into k8scp

The whole point of this repo's bootstrap flow is that **nobody has a
permanent tunnel, route, or SSH path from the LAN/laptop into
`10.100.0.0/24`** — not even to run Ansible. Three things make that work
together, and are worth understanding as a set before touching
`scripts/`:

1. **`kubeadm init/join` is made deterministic before it ever runs.**
   Token, cert hash, and certificate-key are generated once (by the first
   Ansible play, on `master_primary`) and pushed to Vault *before*
   `kubeadm init` executes — no node ever parses another node's stdout to
   find a join command. Every node reads the same three values back from
   Vault independently. See `ansible/site.yml`, plays 4–5.
2. **An ephemeral bootstrap VM is the only thing that ever touches
   `10.100.0.0/24` directly**, and it exists for the duration of one
   `scripts/bootstrap-run.sh` run only:
   - `terraform apply -target=module.node["ci-bootstrap"]`
   - wait for its SSH, generate an inventory whose `ansible_ssh_common_args`
     `ProxyCommand`s every connection through it
   - run `ansible/site.yml`
   - `terraform destroy -target=module.node["ci-bootstrap"]` — wired into
     a `trap ... EXIT`, so it happens even if the playbook fails partway
     through, not just on a clean run.
3. **Vault itself has a native address on the same subnet**
   (`10.100.0.5`, via `scripts/vault-attach-k8scp.sh` — a second NIC on
   the existing Vault LXC, bridged straight onto the `k8scp` SDN VNet).
   This isn't required for the bootstrap flow to work (the subnet's own
   `subnet_snat` would get k8s nodes to Vault via the LAN address too),
   but it removes a dependency on `primary_exit_node` being up/correct
   for something as basic as reading a join token, and it's a one-time
   change — run it once, forget about it.

None of this means "SSH access never happens" — it means access is
always short-lived and initiated by a script, not standing infrastructure
someone could forget was open.

## Known topology limitation

3 masters on 2 physical hosts (the default in `env/nodes/variables.tf`) is
a demo/reference topology, not real HA: losing one host takes down 2 of 3
masters and breaks etcd quorum. Options if that's not acceptable:

1. Leave it as-is — reference/learning, not production.
2. A third physical node (even a lightweight one, as a non-voting etcd
   learner).
3. Accept single-master, or use k3s instead (embedded etcd is optional,
   lighter resource requirements) instead of full kubeadm HA.

## Before the first apply

1. Validate `mod/pve-vm` if the VM somehow doesn't get created — the
   variable names here were hand-synced against the real `bpg/proxmox`
   API, not autogenerated; a newer provider version could in theory have
   renamed something in the `clone`/`initialization`/etc. blocks.
2. Check the bucket/endpoint in both `env/*`'s `backend.tf` (`tfstate` /
   `192.168.100.100:9000`) — adjust if your MinIO uses different ones.
3. `SDN.Allocate` on the TerraformProv role (see above) — without it the
   first `apply` in `env/network` fails with a `403` on creating the zone
   itself.
4. The golden image (`template_vm_id`, defaults to 9000 on `bare-pve` /
   9001 on `pve-rog` — see `env/nodes/locals.tf`) must already exist on
   both nodes the cluster's VMs will land on.
5. `scripts/vault-attach-k8scp.sh` run once against the Proxmox host that
   owns Vault's CT — not required before the first apply, but do it
   before relying on the bootstrap flow's Vault reads/writes (see
   [The "closed box"](#the-closed-box-no-standing-access-into-k8scp)
   above).

## Secrets & Vault

Everything the bootstrap flow needs from Vault lives under
`proxmox/k8s-join` (the `kubeadm` token, cert hash, certificate-key —
written once by `ansible/site.yml`'s play 4, read by every node in play
5) plus whatever `scripts/vault-apply-wrapper.sh`-style sourcing already
gives you for Terraform itself (`TF_VAR_proxmox_api_token`,
`TF_VAR_vm_ssh_public_key`, `TF_VAR_ci_ssh_public_key`).

`scripts/bootstrap-run.sh` doesn't log into Vault itself — it expects
`vault login -method=userpass username=<you>` already done in the current
shell and just reads the cached token via `vault print token`. Same
pattern as every manually-applied environment in `iac-proxmox-lab`.

## Apply

```bash
cd env/network && terraform init && terraform apply
cd ../nodes    && terraform init && terraform apply
```

`env/nodes` reads `vnet_id` from `env/network` via
`terraform_remote_state` (the same MinIO backend, key
`k8s-network/terraform.tfstate`) — `env/network` must be applied first.

This step provisions the masters/workers themselves (`ci-bootstrap` is
**not** applied here — it's created and destroyed by
`scripts/bootstrap-run.sh` around the Ansible run, see below).

## Bootstrap the cluster

```bash
source /path/to/iac-proxmox-lab/scripts/vault-apply-wrapper.sh   # once per shell
vault login -method=userpass username=<you>                     # once per token TTL

export CONTROL_PLANE_VIP=10.100.0.10   # keepalived VIP, not one of var.nodes' addresses
export GITHUB_USER=Tsuyakashi
export GITHUB_REPO=devops-handbook
export GITHUB_TOKEN=<pat with repo scope, for the ArgoCD repo secret>

./scripts/bootstrap-run.sh
```

This is the entire "after apply" step — `scripts/bootstrap-run.sh` brings
up the bootstrap VM, generates the inventory, runs `ansible/site.yml`
(kubeadm init/join, keepalived VIP, Flannel, local-path-provisioner,
ArgoCD + Ingress NGINX, the root ArgoCD Application), and tears the
bootstrap VM down again — see
[The "closed box"](#the-closed-box-no-standing-access-into-k8scp) above
for why it's structured this way instead of a persistent runner or a
one-off manual `ansible-playbook` call.

Safe to re-run: every `kubeadm init`/`join`/`token`-writing task in
`ansible/site.yml` is idempotent (`creates:`/`when:` guards), so re-running
`bootstrap-run.sh` against an already-initialized cluster is a no-op on
the k8s side and just re-applies the Ansible plays that aren't
init-guarded (ArgoCD/Ingress NGINX Helm releases, the root Application).

## Day-2 access (no persistent tunnel)

Anything that needs to reach a live node directly — `kubectl` from
outside the cluster, debugging a stuck pod, adding a worker later — goes
through the same bootstrap pattern, not a standing SSH path:

```bash
./scripts/bootstrap-run.sh   # re-run; idempotent guards make this cheap
```

or, for a one-off manual session without running the whole playbook,
apply/destroy the bootstrap node directly:

```bash
terraform -chdir=env/nodes apply -auto-approve -target='module.node["ci-bootstrap"]'
ssh -J ubuntu@10.100.0.99 ubuntu@10.100.0.11   # or whichever node
terraform -chdir=env/nodes destroy -auto-approve -target='module.node["ci-bootstrap"]'
```
