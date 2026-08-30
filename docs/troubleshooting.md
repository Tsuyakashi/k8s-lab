# Troubleshooting

## EVPN default-route leak into the host's main routing table

**Symptom.** Some time after `terraform apply` in `env/network` (not
necessarily immediately — reconvergence can take a few minutes), IPv6 (and
potentially IPv4) connectivity from one or both Proxmox hosts to the
outside world silently degrades. First visible symptom in this project was
`tailscaled` losing its DERP/control-plane connection:

```
tailscaled[...]: control: bootstrapDNS(...) error: dial tcp6 [...]:443: connect: no route to host
```

or, on the affected side, `context deadline exceeded` on every DERP/control
endpoint despite the host having working connectivity moments earlier.

**Root cause.** `mod/sdn-network` sets `advertise_subnets = true` and a
`primary_exit_node`. FRR's `router bgp <asn> vrf <vrf_id>` instance issues
`default-originate ipv4`/`default-originate ipv6` for the VRF. Separately,
the *main* `router bgp <asn>` instance (not the vrf one) has:

```
address-family ipv4 unicast
  import vrf vrf_k8scp
address-family ipv6 unicast
  import vrf vrf_k8scp
```

`import vrf` pulls the **entire** RIB of `vrf_k8scp` — including the
self-originated default — straight into the host's main routing table. This
is confirmed as expected (if undesirable) Proxmox SDN behavior, not a bug
specific to this repo: see the Proxmox forum threads linked in the README's
"Known EVPN caveat" section, in particular the ones confirming `import vrf`
as the leak path and devs acknowledging it as by-design.

Observed here specifically on the **non-primary exit node**
(`pve-rog`, since `primary_exit_node = "bare-pve"`), appearing as:

```
default nhid ... via ::ffff:192.168.100.30 dev vrfbr_k8scp proto bgp metric 20 onlink pref medium
```

`bare-pve` (the primary) did not exhibit the leak in testing, but the fix
below is applied to **all** `exit_nodes` regardless — the underlying
`import vrf` statement is identical on every node running the EVPN
controller, so there's no structural reason it couldn't happen there too.

**Fix.** `scripts/frr-evpn-safety.sh` — idempotent, run on every node in
`var.exit_nodes` (currently `bare-pve`, `pve-rog`). It appends a route-map
to `/etc/frr/frr.conf.local` that permits everything except `0.0.0.0/0`
and `::/0` through the `import vrf` statement:

```
router bgp 65000
 address-family ipv4 unicast
  import vrf route-map K8SCP_BLOCK_VRF_DEFAULT
 address-family ipv6 unicast
  import vrf route-map K8SCP_BLOCK_VRF_DEFAULT
```

This blocks only the default route from leaking; specific routes
(`10.100.0.0/24` etc.) still import normally, so inter-node connectivity
over the VNet is unaffected.

**Critical gotcha: `.local` merge is not triggered by `systemctl reload
frr`.** `frr.conf.local` is a Proxmox SDN convention, not something FRR
itself reads directly (this cluster runs `service
integrated-vtysh-config`, so FRR only ever reads the single generated
`/etc/frr/frr.conf`). The `.local` file only gets merged into
`frr.conf` during Proxmox's own SDN config regeneration cycle. A plain
`systemctl reload frr` re-reads the *existing* `frr.conf` — which doesn't
have the merge yet — and reports success while changing nothing. The
actual trigger is:

```bash
pvesh set /cluster/sdn
```

(the same call used to force a config push without touching the
zone/vnet Terraform resources themselves). `scripts/frr-evpn-safety.sh`
calls this instead of `systemctl reload frr` for exactly this reason —
if you're re-deriving this script from scratch, don't skip it, the
script will silently no-op otherwise.

**Verification:**

```bash
ssh <host> "vtysh -c 'show route-map K8SCP_BLOCK_VRF_DEFAULT'"   # loaded + Invoked count > 0
ssh <host> "ip -6 route show | grep default"                     # must be empty
ssh <host> "ip route show | grep default"                        # only the LAN default via vmbr0
```

**Re-running after any `env/network` change.** `frr.conf.local` lives
outside Terraform state entirely. A no-op `terraform apply` (refresh only,
0 changes) does not touch it and does not need a re-run. But any apply
that actually **recreates** the zone/vnet (changed `vrf_vxlan`, `mtu`,
`exit_nodes`, etc.) regenerates `frr.conf` from scratch via
`reloadnetworkall` — at which point it's unverified whether the `.local`
merge survives a full zone recreation the same way it survives a
`pvesh set /cluster/sdn` push. **Always re-run
`scripts/frr-evpn-safety.sh` on every exit node immediately after any
`env/network` apply that shows non-zero changes**, before relying on
tailscale/SSH connectivity to those hosts for anything else. The script
is idempotent (checks for its own marker) — safe to run unconditionally
every time, don't try to guess whether it's "probably still fine".

**Why this surfaced as a tailscale problem first, not an SDN problem.**
The leak degrades *host* connectivity, not VM/VNet connectivity. LAN
reachability (SSH from a runner on the same subnet) stayed up throughout
both incidents — only the host's own outbound path to the wider internet
(and by extension anything depending on it, like tailscaled reaching
DERP) was affected. If you're debugging something that looks like "the
host is randomly losing internet access" shortly after touching
`env/network`, check `ip -6 route show` for a stray `vrfbr_*` default
before assuming it's an ISP/ARP/unrelated issue.
