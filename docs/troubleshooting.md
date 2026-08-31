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


## kubeadm-config.yaml.j2: silent YAML indentation break

**Symptom.** `kubeadm init` fails immediately (`rc=1`, `<0.1s`), before
doing anything cluster-related:

```
could not interpret GroupVersionKind; unmarshal error: error converting
YAML to JSON: yaml: line 4: did not find expected key
```

**Root cause.** In a block sequence (`- token: ...`), a mapping key's
implicit indentation is exactly the width of `"- "` — 2 characters, no
more, no less. `ansible/templates/kubeadm-config.yaml.j2`'s
`bootstrapTokens` block needs `ttl:` aligned exactly under `token:`:

```yaml
bootstrapTokens:
- token: "{{ k8s_join_token }}"
  ttl: "24h0m0s"
```

1 space too few, or any amount too many, produces the same class of
error with a different line number. Since this is a Jinja2 template, not
plain YAML, `yamllint`/`yaml.safe_load` can't validate it directly —
eyeball it: `t` in `ttl` must sit in the same column as `t` in `token`.

**Note on re-running.** `Deploy kubeadm config template` only fires
`when: not admin_conf.stat.exists` — if `kubeadm init` failed, that
condition is still true next run, so fixing the template and re-running
`bootstrap-run.sh` is enough; nothing to clean up on the node itself.

## Stale ARP entry for the keepalived VIP across EVPN hosts

**Symptom.** After a successful `kubeadm init`/`join`, one or more nodes
stay `NotReady` indefinitely. `kubectl describe node <node>` /
kubelet logs show repeated failures talking to the API server at the
`control_plane_vip`. Direct TCP `connect()` to the VIP succeeds, but the
TLS handshake past the initial Client Hello hangs until timeout — while
the same test against the actual node IP (bypassing the VIP) completes
instantly.

**Root cause.** keepalived's default behavior is to send a single
gratuitous ARP when a node enters `MASTER` state, not to repeat it. Proxmox
SDN's EVPN fabric doesn't guarantee that one-shot broadcast reaches every
node — especially across nodes on different physical hosts. If a node's
ARP cache learned the VIP's MAC before/independently of the real
failover (e.g. a previous MASTER, or first bring-up ordering), the entry
can go stale and stay `REACHABLE` (NUD doesn't re-probe it), silently
directing traffic to the wrong node's MAC indefinitely.

Confirm by comparing, on the affected node:
```bash
ip neigh show <vip>          # MAC it currently resolves to
```
against the real MAC on whichever node currently holds the VIP:
```bash
ip link show <interface> | grep ether
```
A mismatch confirms it. `arping -I <iface> -c 3 <vip>` on the affected
node forces a re-resolve and is enough to unblock things immediately, but
doesn't survive the next failover.

**Fix.** `ansible/templates/keepalived.conf.j2`'s `vrrp_instance` needs
periodic GARP, not just the one-shot on transition:
```
  garp_master_delay 1
  garp_master_repeat 5
  garp_master_refresh 30
  garp_master_refresh_repeat 2
```
`garp_master_refresh 30` is what matters — resends GARP every 30s while
in MASTER state, which papers over any single dropped/suppressed
broadcast. Already applied in the template as of this writing.

## ArgoCD Helm release silently marked `failed`, CRDs never applied

**Symptom.** Play 11 (`Deploy Root Application`) fails with:
```
Failed to find exact match for argoproj.io/v1alpha1.Application by
[kind, name, singularName, shortNames]
```
`kubectl get crd applications.argoproj.io` returns `NotFound`, even
though `Install ArgoCD` in Play 10 reported `ok` (not `changed`).

**Root cause.** If ArgoCD's `argocd-redis-secret-init` pre-install hook
can't schedule in time (e.g. because a worker node is transiently
`NotReady` — see the ARP issue above), Helm marks the whole release
`failed` and never gets to applying the chart's CRDs/templates. On the
*next* run, `kubernetes.core.helm` without the `helm-diff` plugin uses a
simplified idempotency check: it sees a release named `argocd` already
exists and reports `ok`, without noticing its status is `failed` — so it
never retries the install.

Confirm: `helm -n argocd status argocd` — `STATUS: failed`.

**Fix.** Added an explicit check  cleanup before `Install ArgoCD` in
Play 10:
```yaml
- name: Check existing ArgoCD release status
  command: helm -n argocd status argocd -o json
  register: argocd_status
  changed_when: false
  failed_when: false

- name: Remove ArgoCD release if it's in a failed state
  command: helm -n argocd uninstall argocd --wait
  when:
    - argocd_status.rc == 0
    - (argocd_status.stdout | from_json).info.status != "deployed"
```
This makes any future hook-timeout (or any other cause of a `failed`
release) self-heal on the next `bootstrap-run.sh`, instead of getting
permanently stuck reporting `ok` on a broken release.