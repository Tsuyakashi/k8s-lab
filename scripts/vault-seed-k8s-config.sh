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
# Uses the LAN address, same as vault-k8s-policy-init.sh — this script
# runs from an operator's laptop, which has no route into 10.100.0.0/24
# (that's the whole reason ci-bootstrap got a second NIC in the first
# place). Never point VAULT_ADDR at 10.100.0.5 here — that address only
# means anything from inside k8scp (see scripts/bootstrap-run.sh's
# VAULT_ADDR_K8SCP, which is a completely separate concern: what the k8s
# nodes themselves dial, not what this script dials).
#
# Usage:
#   VAULT_ADDR=http://192.168.100.200:8200 ./scripts/vault-seed-k8s-config.sh

set -euo pipefail
: "${VAULT_ADDR:?set VAULT_ADDR before running (e.g. http://192.168.100.200:8200)}"

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
