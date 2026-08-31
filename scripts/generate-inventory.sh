#!/bin/bash
# Читает terraform output env/nodes -> генерирует inventory.ini с
# детерминированным выбором master_primary (sorted()[0], а не "первый в
# var.nodes" — смена порядка полей в variables.tf не должна тихо менять,
# какая нода становится primary).
#
# ProxyCommand ходит на bootstrap_lan_ip (LAN-адрес второго NIC
# ci-bootstrap), НЕ на её k8scp-адрес (10.100.0.99) — оператор запускает
# это с ноутбука, у которого в 10.100.0.0/24 маршрута нет вообще. Сама
# bootstrap-нода при этом форвардит трафик (-W %h:%p) на реальные
# k8s-адреса дальше, потому что её ПЕРВИЧНЫЙ интерфейс по-прежнему сидит
# в k8scp — см. mod/pve-vm's second_network / env/nodes/main.tf.

set -euo pipefail

TF_DIR="${1:-env/nodes}"
OUT="${2:-/tmp/inventory.ini}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ci_key}"

cd "$TF_DIR"
terraform output -json > /tmp/tf_outputs_full.json
cd - > /dev/null

python3 - "$OUT" "$SSH_KEY" <<'PYEOF'
import json, sys

out_path = sys.argv[1]
ssh_key = sys.argv[2]
outputs = json.load(open("/tmp/tf_outputs_full.json"))
data = outputs["ips_by_role"]["value"]
bootstrap_lan_ip = outputs.get("bootstrap_lan_ip", {}).get("value", "")

masters = data.get("master", [])
workers = data.get("worker", [])

if not masters:
    sys.exit("no master nodes in terraform output — aborting")
if not bootstrap_lan_ip:
    sys.exit(
        "bootstrap_lan_ip is empty — either ci-bootstrap wasn't applied "
        "(scripts/bootstrap-run.sh should have done this before calling "
        "this script) or nodes[\"ci-bootstrap\"].lan_ip isn't set in "
        "env/nodes/variables.tf"
    )

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
    f'-i {ssh_key} ubuntu@{bootstrap_lan_ip}"'
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
      f"{len(workers)} workers, proxied via bootstrap LAN ip={bootstrap_lan_ip}")
PYEOF
