#!/bin/bash
#
# Prevents EVPN Type-5 default-route leak from vrf_k8scp into the host's
# main routing table via "import vrf vrf_k8scp" in the main `router bgp`
# instance (confirmed as expected-but-undesirable behavior by Proxmox devs
# on forum — see k8s-lab README "Known EVPN caveat").
#
# Root cause (confirmed against live /etc/frr/frr.conf on bare-pve):
# the auto-generated config already has a route-map on the VTEP peer
# (MAP_VTEP_IN) blocking default from EVPN Type-5 NLRI — but that only
# filters the overlay peer exchange. It does NOT cover the separate
# `import vrf vrf_k8scp` statement in the main `router bgp 65000` block,
# which pulls the VRF's own default-originate route (from
# `router bgp 65000 vrf vrf_k8scp` / `default-originate ipv4/ipv6`)
# straight into the main table. That's the actual leak path.
#
# Fix: attach a route-map to the `import vrf` statement itself, so the
# VRF's other (more specific) routes still get imported, only the
# default is blocked.
#
# Idempotent: safe to re-run after any SDN zone re-apply.
# Usage: run on each node in var.exit_nodes (bare-pve, pve-rog).

set -e

FRR_LOCAL=/etc/frr/frr.conf.local
MARKER="# managed-by: k8s-lab/scripts/frr-evpn-safety.sh"

if [ -f "$FRR_LOCAL" ] && grep -qF "$MARKER" "$FRR_LOCAL"; then
    echo "frr.conf.local already configured, skipping."
    exit 0
fi

# Names deliberately distinct from Proxmox's own auto-generated
# only_default/only_default_v6 prefix-lists (used by MAP_VTEP_IN) to
# avoid any collision when frr.conf.local is merged with the generated
# config.
cat >> "$FRR_LOCAL" <<'EOF'
# managed-by: k8s-lab/scripts/frr-evpn-safety.sh
!
ip prefix-list K8SCP_ONLY_DEFAULT seq 10 permit 0.0.0.0/0
ipv6 prefix-list K8SCP_ONLY_DEFAULT_V6 seq 10 permit ::/0
!
route-map K8SCP_BLOCK_VRF_DEFAULT deny 10
 match ip address prefix-list K8SCP_ONLY_DEFAULT
exit
!
route-map K8SCP_BLOCK_VRF_DEFAULT deny 20
 match ipv6 address prefix-list K8SCP_ONLY_DEFAULT_V6
exit
!
route-map K8SCP_BLOCK_VRF_DEFAULT permit 30
exit
!
router bgp 65000
 address-family ipv4 unicast
  import vrf route-map K8SCP_BLOCK_VRF_DEFAULT
 exit-address-family
 address-family ipv6 unicast
  import vrf route-map K8SCP_BLOCK_VRF_DEFAULT
 exit-address-family
exit
!
EOF

echo "Wrote $FRR_LOCAL, triggering SDN config regeneration..."
# systemctl reload/restart frr is NOT enough — .local merge happens only
# during Proxmox SDN's own regeneration cycle (reloadnetworkall), which
# `pvesh set /cluster/sdn` triggers explicitly without touching zone/vnet
# config itself.
pvesh set /cluster/sdn

echo "Done. Verify:"
echo "  vtysh -c 'show route-map K8SCP_BLOCK_VRF_DEFAULT'"
echo "  ip -6 route show | grep default   # should be empty"