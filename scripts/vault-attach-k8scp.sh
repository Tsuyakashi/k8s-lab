#!/bin/bash
#
# Run on the Proxmox host where CT 300 (Vault) actually lives — bare-pve
# (ssh root@bare-pve 'bash -s' < scripts/vault-attach-k8scp.sh).
#
# Adds a second network interface (net1) on the existing Vault LXC,
# bridged directly to the k8scp SDN VNet (k8svncp — see
# k8s-lab/env/network/main.tf) with a static address on 10.100.0.0/24.
# This gives Vault a native presence on that subnet instead of relying on
# subnet_snat/primary_exit_node NAT for k8s nodes to reach it — one fewer
# moving part between "cluster tries to read a join secret" and "Vault
# answers", and it keeps working even if primary_exit_node ever fails
# over to pve-rog (mod/sdn-network's own README already flags that
# failover as a manual/HA concern, not automatic).
#
# net0 (LAN, 192.168.100.200/24) is untouched — this only adds net1,
# it doesn't move or replace anything. Vault's own listener already binds
# 0.0.0.0:8200 (see vault.hcl in vault-lxc-init.sh), so nothing in Vault's
# own config needs to change for it to start answering on the new
# interface once it's up.
#
# CT 300 is NOT Terraform-managed (deliberately, see iac-proxmox-lab's
# README "State backend lives off both" reasoning applied the same way to
# Vault) — this is a plain `pct set` + reboot, same class of operation as
# minio-lxc-init.sh/vault-lxc-init.sh's own idempotent guards.
#
# Idempotent: checks the current net1 config before touching anything.

set -euo pipefail

CTID=300
K8SCP_BRIDGE="k8svncp"      # var.vnet_id from k8s-lab/env/network/main.tf
VAULT_K8SCP_IP="10.100.0.5/24"

CURRENT_NET1="$(pct config "${CTID}" | awk '/^net1:/{print}' || true)"

if echo "${CURRENT_NET1}" | grep -q "bridge=${K8SCP_BRIDGE}" && \
   echo "${CURRENT_NET1}" | grep -q "ip=${VAULT_K8SCP_IP}"; then
    echo "CT ${CTID} already has net1 on ${K8SCP_BRIDGE} at ${VAULT_K8SCP_IP}, skipping."
    exit 0
fi

echo "Attaching CT ${CTID} to ${K8SCP_BRIDGE} at ${VAULT_K8SCP_IP} (net1)..."
pct set "${CTID}" --net1 "name=eth1,bridge=${K8SCP_BRIDGE},ip=${VAULT_K8SCP_IP}"

if [ "$(pct status "${CTID}" | awk '{print $2}')" = "running" ]; then
    echo "Rebooting CT ${CTID} to bring up the new interface..."
    pct reboot "${CTID}"
    sleep 5
fi

echo "Done. Verify from inside CT ${CTID}:"
echo "  pct exec ${CTID} -- ip -4 addr show eth1"
echo "Verify from a k8s node once it's up (no NAT hop involved now):"
echo "  curl -s http://${VAULT_K8SCP_IP%/*}:8200/v1/sys/health | head -c 200"
