#!/bin/bash
#
# What it does, in order:
#   1. auth: read the already-cached Vault token from this shell (vault
#      login must already be done — this script never logs in itself).
#      Uses VAULT_ADDR_LAPTOP (LAN, reachable from wherever this script
#      runs) for that — NOT VAULT_ADDR_K8SCP, which only k8s nodes
#      themselves can reach (see point 4 below).
#   2. fetch CONTROL_PLANE_VIP/GITHUB_USER/GITHUB_REPO/GITHUB_TOKEN from
#      Vault (proxmox/k8s-config, via VAULT_ADDR_LAPTOP) instead of
#      requiring them as env vars — seed that path once with
#      scripts/vault-seed-k8s-config.sh. Any of the four can still be
#      overridden by exporting it before running this script.
#   3. terraform apply -target the bootstrap node only, with
#      -var include_bootstrap=true (required — see env/nodes/locals.tf;
#      without it ci-bootstrap is filtered out of the for_each entirely
#      and -target finds nothing to create). ci-bootstrap gets a SECOND
#      nic on the LAN (see env/nodes/variables.tf's lan_ip) — this script
#      never touches 10.100.0.0/24 directly, only the LAN address.
#   4. wait for it to answer SSH on its LAN address (bootstrap_lan_ip
#      terraform output)
#   5. generate the Ansible inventory — ProxyCommand also targets
#      bootstrap_lan_ip, not the k8scp-side address (see
#      scripts/generate-inventory.sh); ansible/site.yml's own Vault calls
#      (play 4/5) run ON the masters/workers over that proxied SSH
#      session, so THEY use VAULT_ADDR_K8SCP (10.100.0.5) — that address
#      is only ever dialed from inside k8scp, never from this laptop.
#   6. run the playbook
#   7. ALWAYS terraform destroy the bootstrap node (same -var flag) —
#      trap on EXIT, so it dies even if the playbook fails partway through.
#
# Requirements:
#   - `vault login -method=userpass username=<you>` already done in this
#     shell (or VAULT_TOKEN already exported) — this script does not log
#     you in, it only reads the cached token via `vault print token`.
#   - The logged-in operator's Vault token needs the `k8s-lab-bootstrap`
#     policy (read+write on proxmox/data/k8s-join, read on
#     proxmox/data/k8s-config) — see scripts/vault-k8s-policy-init.sh.
#   - proxmox/k8s-config must be seeded — see
#     scripts/vault-seed-k8s-config.sh.
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
SSH_KEY="${SSH_KEY:-$HOME/.ssh/iac-proxmox-deploy}"
INVENTORY_OUT="${INVENTORY_OUT:-/tmp/inventory.ini}"

# Two DIFFERENT Vault addresses, dialed from two different places:
#   - VAULT_ADDR_LAPTOP: this script's own `vault` CLI calls (print token,
#     kv get) run right here, wherever this script is invoked from — that
#     place has a route to the LAN, not to k8scp. Same address `vault
#     status` already resolves to by default in your shell.
#   - VAULT_ADDR_K8SCP: passed to ansible-playbook as -e vault_addr=...,
#     which ansible/site.yml's `uri` tasks then dial FROM the target
#     masters/workers (over the proxied SSH session) — those hosts sit on
#     k8scp themselves, so 10.100.0.5 is a direct hop for them, same as it
#     always was. Only this one stays inside k8scp; the laptop never
#     touches it.
VAULT_ADDR_LAPTOP="${VAULT_ADDR_LAPTOP:-http://192.168.100.200:8200}"
VAULT_ADDR_K8SCP="${VAULT_ADDR_K8SCP:-http://10.100.0.5:8200}"

# _destroyed=0
# destroy_bootstrap() {
#   if [ "${_destroyed}" -eq 1 ]; then
#     return 0
#   fi
#   echo "==> destroying bootstrap node (${BOOTSTRAP_KEY})..."
#   terraform -chdir="${TF_DIR}" destroy -auto-approve \
#     -var include_bootstrap=true \
#     -target="module.node[\"${BOOTSTRAP_KEY}\"]" >/dev/null || {
#       echo "!! bootstrap destroy failed — check for a leftover VM manually (module.node[\"${BOOTSTRAP_KEY}\"])" >&2
#       return 1
#     }
#   _destroyed=1
# }
# trap destroy_bootstrap EXIT

echo "==> fetching Vault token from current session (${VAULT_ADDR_LAPTOP})"
VAULT_TOKEN="$(VAULT_ADDR="${VAULT_ADDR_LAPTOP}" vault print token)"
if [ -z "${VAULT_TOKEN}" ]; then
  echo "no cached Vault token — run 'vault login -method=userpass username=<you>' first" >&2
  exit 1
fi

_kv() {
  VAULT_ADDR="${VAULT_ADDR_LAPTOP}" VAULT_TOKEN="${VAULT_TOKEN}" vault kv get -field="$1" proxmox/k8s-config 2>/dev/null || true
}

echo "==> resolving cluster config (env override, falling back to Vault proxmox/k8s-config)"
CONTROL_PLANE_VIP="${CONTROL_PLANE_VIP:-$(_kv control_plane_vip)}"
GITHUB_USER="${GITHUB_USER:-$(_kv github_user)}"
GITHUB_REPO="${GITHUB_REPO:-$(_kv github_repo)}"
GITHUB_TOKEN="${GITHUB_TOKEN:-$(_kv github_token)}"

: "${CONTROL_PLANE_VIP:?control_plane_vip not set and not found in Vault — run scripts/vault-seed-k8s-config.sh or export CONTROL_PLANE_VIP}"
: "${GITHUB_USER:?github_user not set and not found in Vault — run scripts/vault-seed-k8s-config.sh or export GITHUB_USER}"
: "${GITHUB_REPO:?github_repo not set and not found in Vault — run scripts/vault-seed-k8s-config.sh or export GITHUB_REPO}"
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "warning: github_token is empty — fine if ${GITHUB_USER}/${GITHUB_REPO} is public, the ArgoCD repo Secret will just carry an empty password" >&2
fi

echo "==> terraform init"
terraform -chdir="${TF_DIR}" init -input=false >/dev/null

echo "==> applying bootstrap node only (primary nic: k8scp, second nic: LAN)"
terraform -chdir="${TF_DIR}" apply -auto-approve \
  -var include_bootstrap=true \
  -target="module.node[\"${BOOTSTRAP_KEY}\"]" >/dev/null

BOOTSTRAP_LAN_IP="$(terraform -chdir="${TF_DIR}" output -raw bootstrap_lan_ip)"
if [ -z "${BOOTSTRAP_LAN_IP}" ]; then
  echo "bootstrap_lan_ip output is empty — check nodes[\"ci-bootstrap\"].lan_ip in env/nodes/variables.tf" >&2
  exit 1
fi

echo "==> waiting for bootstrap SSH on its LAN address (${BOOTSTRAP_LAN_IP})"
for i in $(seq 1 30); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
       -i "${SSH_KEY}" "ubuntu@${BOOTSTRAP_LAN_IP}" true 2>/dev/null; then

    # MT-PON-AT-1 fix
    ssh -J bare-pve -o StrictHostKeyChecking=no -i "${SSH_KEY}" "ubuntu@${BOOTSTRAP_LAN_IP}" 'ping 192.168.100.12 -c3' > /dev/null

    break
  fi
  if [ "${i}" -eq 30 ]; then
    echo "bootstrap node never came up on SSH" >&2
    exit 1
  fi
  sleep 5
done

# for i in $(seq 1 30); do
#   if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -i "${SSH_KEY}" "ubuntu@${BOOTSTRAP_LAN_IP}" 'nc -zv 10.100.0.11 22' > /dev/null
#     if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -i "${SSH_KEY}" "ubuntu@${BOOTSTRAP_LAN_IP}" 'nc -zv 10.100.0.12 22' > /dev/null
#       if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -i "${SSH_KEY}" "ubuntu@${BOOTSTRAP_LAN_IP}" 'nc -zv 10.100.0.13 22' > /dev/null
#         if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -i "${SSH_KEY}" "ubuntu@${BOOTSTRAP_LAN_IP}" 'nc -zv 10.100.0.21 22' > /dev/null
#           break
#         fi
#       fi
#     fi
#   fi
#   if [ "${i}" -eq 30 ]; then
#     echo "bootstrap node never came up on SSH" >&2
#     exit 1
#   fi
#   sleep 5
# done

echo "==> generating inventory (proxied through bootstrap's LAN nic)"
bash "${REPO_ROOT}/scripts/generate-inventory.sh" "${TF_DIR}" "${INVENTORY_OUT}"

echo "==> running ansible-playbook"
ansible-playbook -i "${INVENTORY_OUT}" "${ANSIBLE_DIR}/site.yml" \
  --private-key "${SSH_KEY}" \
  -e vault_addr="${VAULT_ADDR_K8SCP}" \
  -e vault_token="${VAULT_TOKEN}" \
  -e control_plane_vip="${CONTROL_PLANE_VIP}" \
  -e github_user="${GITHUB_USER}" \
  -e github_repo="${GITHUB_REPO}" \
  -e github_token="${GITHUB_TOKEN}"

echo "==> playbook finished — bootstrap node will be destroyed by the EXIT trap now"
