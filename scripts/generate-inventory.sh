#!/bin/bash
# Читает terraform output env/nodes -> генерирует inventory.ini с
# детерминированным выбором master_primary (sorted()[0], а не "первый в
# var.nodes" — смена порядка полей в variables.tf не должна тихо менять,
# какая нода становится primary).
#
# Также подставляет ProxyCommand через bootstrap-ноду (роль "bootstrap" в
# ips_by_role) — LAN-раннер/оператор сам не имеет маршрута в 10.100.0.0/24,
# только bootstrap-VM, поднятая на время прогона (см. scripts/bootstrap-run.sh).

set -euo pipefail

TF_DIR="${1:-env/nodes}"
OUT="${2:-/tmp/inventory.ini}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ci_key}"

cd "$TF_DIR"
terraform output -json ips_by_role > /tmp/ips_by_role.json
cd - > /dev/null

python3 - "$OUT" "$SSH_KEY" <<'PYEOF'
import json, sys

out_path = sys.argv[1]
ssh_key = sys.argv[2]
data = json.load(open("/tmp/ips_by_role.json"))

masters = data.get("master", [])
workers = data.get("worker", [])
bootstrap = data.get("bootstrap", [])

if not masters:
    sys.exit("no master nodes in terraform output — aborting")
if not bootstrap:
    sys.exit("no bootstrap node in terraform output — aborting (see scripts/bootstrap-run.sh)")

bootstrap_ip = bootstrap[0]["ip"]
primary = sorted(masters, key=lambda n: n["name"])[0]

lines = ["[masters]"]
for n in masters:
    lines.append(f'{n["name"]} ansible_host={n["ip"]}')

lines += ["", "[master_primary]", f'{primary["name"]} ansible_host={primary["ip"]}']

lines += ["", "[master_secondary]"]
for n in masters:
    if n["name"] != primary["name"]:
        lines.append(f'{n["name"]} ansible_host={n["ip"]}')

lines += ["", "[workers]"]
for n in workers:
    lines.append(f'{n["name"]} ansible_host={n["ip"]}')

proxy = (
    f'-o ProxyCommand="ssh -o StrictHostKeyChecking=no -W %h:%p '
    f'-i {ssh_key} ubuntu@{bootstrap_ip}"'
)

lines += [
    "",
    "[all:vars]",
    "ansible_user=ubuntu",
    "ansible_python_interpreter=/usr/bin/python3",
    f"ansible_ssh_common_args='-o StrictHostKeyChecking=no {proxy}'",
]

with open(out_path, "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"wrote {out_path}: {len(masters)} masters (primary={primary['name']}), "
      f"{len(workers)} workers, proxied via bootstrap={bootstrap_ip}")
PYEOF
