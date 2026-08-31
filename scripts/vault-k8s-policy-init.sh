#!/bin/bash
#
# scripts/vault-k8s-policy-init.sh
#
# Extends Vault access for k8s-lab's bootstrap flow, on top of whatever
# iac-proxmox-lab/scripts/vault-userpass-init.sh already set up for this
# operator (operator-manual-apply policy, used for TF_VAR_* fetches via
# vault-apply-wrapper.sh). Two new paths, granted through a separate
# policy so k8s-lab's needs don't get silently baked into the other
# repo's policy definition:
#
#   - proxmox/data/k8s-join   — read+write. ansible/site.yml's play 4
#     writes the kubeadm token/cert-key/ca-hash once (first-ever init
#     only); every node in play 5 reads them back. Both operations run
#     with whatever Vault token scripts/bootstrap-run.sh picks up via
#     `vault print token` — that token needs both capabilities.
#   - proxmox/data/k8s-config — read only. control_plane_vip/github_user/
#     github_repo/github_token, seeded by scripts/vault-seed-k8s-config.sh
#     and read by scripts/bootstrap-run.sh on every invocation.
#
# Run once against Vault:
#   VAULT_ADDR=http://192.168.100.200:8200 ./scripts/vault-k8s-policy-init.sh
#
# (Use the LAN address here, not 10.100.0.5 — this attaches a policy to an
# existing userpass account, unrelated to which network path k8s nodes
# themselves use to reach Vault later.)

set -euo pipefail
: "${VAULT_ADDR:?set VAULT_ADDR before running (e.g. http://192.168.100.200:8200)}"

vault policy write k8s-lab-bootstrap - <<POLICY
path "proxmox/data/k8s-join" {
  capabilities = ["create", "read", "update"]
}
path "proxmox/data/k8s-config" {
  capabilities = ["read"]
}
POLICY

read -rp "Vault username to attach this policy to (existing operator-manual-apply user from iac-proxmox-lab): " VAULT_USER

EXISTING="$(vault read -field=token_policies "auth/userpass/users/${VAULT_USER}" 2>/dev/null || echo '')"
# vault read prints something like "[default operator-manual-apply]" —
# strip brackets/commas and dedupe against the new policy.
NEW_POLICIES=$(echo "${EXISTING} k8s-lab-bootstrap" | tr -d '[],' | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd, -)

vault write "auth/userpass/users/${VAULT_USER}" \
  token_policies="${NEW_POLICIES}"

echo "Policy k8s-lab-bootstrap attached to ${VAULT_USER} (token_policies now: ${NEW_POLICIES})."
echo "Refresh the session token so it picks up the new policy:"
echo "  vault login -method=userpass username=${VAULT_USER}"
echo "Then seed the config once:"
echo "  ./scripts/vault-seed-k8s-config.sh"
