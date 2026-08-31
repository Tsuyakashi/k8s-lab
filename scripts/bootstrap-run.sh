#!/bin/bash
#
# Replaces .github/workflows/k8s-bootstrap.yml — no CI job needed for this
# repo's bootstrap flow, it's rare/manual enough (like every other
# environments/* apply in iac-proxmox-lab) to just run from wherever you
# already have Vault + Proxmox SSH access.
#
# What it does, in order:
#   1. terraform apply  -target the bootstrap node only
#   2. wait for it to answer SSH
#   3. generate the Ansible inventory (proxied through the bootstrap node)
#   4. run the playbook
#   5. ALWAYS terraform destroy the bootstrap node — trap on EXIT, so it
#      dies even if the playbook fails partway through. This is the
#      answer to "как умертвлять ноду после": the destroy is not a final
#      step you might forget to run, it's guaranteed by the trap
#      regardless of how the script exits.
#
# Requirements (same pattern as iac-proxmox-lab's vault-apply-wrapper.sh):
#   - `vault login -method=userpass username=<you>` already done in this
#     shell (or VAULT_TOKEN already exported) — this script does not log
#     you in, it only reads the cached token via `vault print token`.
#   - TF_VAR_proxmox_api_token / TF_VAR_vm_ssh_public_key /
#     TF_VAR_ci_ssh_public_key already exported (source
#     iac-proxmox-lab/scripts/vault-apply-wrapper.sh once per shell, or
#     export them yourself).
#   - ~/.ssh/ci_key present and usable against the CI SSH key registered
#     in cloud-init (proxmox/ssh-keys' ci_public_key in Vault).
#
# Usage:
#   source /path/to/iac-proxmox-lab/scripts/vault-apply-wrapper.sh   # once
#   vault login -method=userpass username=<you>                     # once per token TTL
#   ./scripts/bootstrap-run.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${TF_DIR:-$REPO_ROOT/env/nodes}"
ANSIBLE_DIR="${ANSIBLE_DIR:-$REPO_ROOT/ansible}"
BOOTSTRAP_KEY="${BOOTSTRAP_KEY:-ci-bootstrap}"
BOOTSTRAP_IP="${BOOTSTRAP_IP:-10.100.0.99}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ci_key}"
INVENTORY_OUT="${INVENTORY_OUT:-/tmp/inventory.ini}"
# Vault now sits directly on k8scp too (see scripts/vault-attach-k8scp.sh,
# net1 on CT 300 at 10.100.0.5) — no NAT hop through primary_exit_node
# needed for k8s nodes to reach it anymore. Override back to the LAN
# address (192.168.100.200:8200) if that attachment hasn't been applied yet.
VAULT_ADDR="${VAULT_ADDR:-http://10.100.0.5:8200}"
CONTROL_PLANE_VIP="${CONTROL_PLANE_VIP:?set CONTROL_PLANE_VIP before running}"
GITHUB_USER="${GITHUB_USER:?set GITHUB_USER before running}"
GITHUB_REPO="${GITHUB_REPO:-devops-handbook}"
GITHUB_TOKEN="${GITHUB_TOKEN:?set GITHUB_TOKEN before running}"

_destroyed=0
destroy_bootstrap() {
  if [ "${_destroyed}" -eq 1 ]; then
    return 0
  fi
  echo "==> destroying bootstrap node (${BOOTSTRAP_KEY})..."
  terraform -chdir="${TF_DIR}" destroy -auto-approve \
    -target="module.node[\"${BOOTSTRAP_KEY}\"]" || {
      echo "!! bootstrap destroy failed — check for a leftover VM manually (module.node[\"${BOOTSTRAP_KEY}\"])" >&2
      return 1
    }
  _destroyed=1
}
trap destroy_bootstrap EXIT

echo "==> terraform init"
terraform -chdir="${TF_DIR}" init -input=false

echo "==> applying bootstrap node only"
terraform -chdir="${TF_DIR}" apply -auto-approve \
  -target="module.node[\"${BOOTSTRAP_KEY}\"]"

echo "==> waiting for bootstrap SSH (${BOOTSTRAP_IP})"
for i in $(seq 1 30); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
       -i "${SSH_KEY}" "ubuntu@${BOOTSTRAP_IP}" true 2>/dev/null; then
    break
  fi
  if [ "${i}" -eq 30 ]; then
    echo "bootstrap node never came up on SSH" >&2
    exit 1
  fi
  sleep 5
done

echo "==> generating inventory (proxied through bootstrap)"
bash "${REPO_ROOT}/scripts/generate-inventory.sh" "${TF_DIR}" "${INVENTORY_OUT}"

echo "==> fetching Vault token from current session"
VAULT_TOKEN="$(VAULT_ADDR="${VAULT_ADDR}" vault print token)"
if [ -z "${VAULT_TOKEN}" ]; then
  echo "no cached Vault token — run 'vault login -method=userpass username=<you>' first" >&2
  exit 1
fi

echo "==> running ansible-playbook"
ansible-playbook -i "${INVENTORY_OUT}" "${ANSIBLE_DIR}/site.yml" \
  --private-key "${SSH_KEY}" \
  -e vault_addr="${VAULT_ADDR}" \
  -e vault_token="${VAULT_TOKEN}" \
  -e control_plane_vip="${CONTROL_PLANE_VIP}" \
  -e github_user="${GITHUB_USER}" \
  -e github_repo="${GITHUB_REPO}" \
  -e github_token="${GITHUB_TOKEN}"

echo "==> playbook finished — bootstrap node will be destroyed by the EXIT trap now"
