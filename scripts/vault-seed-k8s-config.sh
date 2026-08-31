#!/bin/bash
#
# scripts/vault-seed-k8s-config.sh
#
# One-time: seed proxmox/k8s-config in Vault. scripts/bootstrap-run.sh
# reads control_plane_vip/github_user/github_repo/github_token from this
# path on every run, so they don't need exporting by hand each time.
#
# Requires the logged-in operator's Vault token to have write access to
# proxmox/data/k8s-config — see scripts/vault-k8s-policy-init.sh (run that
# first if this fails with a permission error).
#
# Usage:
#   VAULT_ADDR=http://10.100.0.5:8200 ./scripts/vault-seed-k8s-config.sh
#   (or the LAN address, http://192.168.100.200:8200, if
#   vault-attach-k8scp.sh hasn't been applied yet)

set -euo pipefail
: "${VAULT_ADDR:?set VAULT_ADDR before running}"

read -rp "control_plane_vip (keepalived VIP, NOT one of var.nodes' addresses, e.g. 10.100.0.10): " CP_VIP
read -rp "github_user: " GH_USER
read -rp "github_repo [devops-handbook]: " GH_REPO
GH_REPO="${GH_REPO:-devops-handbook}"
read -rsp "github_token (PAT with repo scope, for the ArgoCD private-repo Secret — leave empty if the repo is public): " GH_TOKEN
echo

vault kv put proxmox/k8s-config \
  control_plane_vip="${CP_VIP}" \
  github_user="${GH_USER}" \
  github_repo="${GH_REPO}" \
  github_token="${GH_TOKEN}"

echo "Done. scripts/bootstrap-run.sh will read these on every run — no more manual export."
echo "Re-run this script any time one of the values changes (it's a plain overwrite, kv v2 keeps history)."
