#!/usr/bin/env bash
# ansible01 only; no inventory edits or remote installation.
set -euo pipefail
umask 077
test "$(hostname -s)" = ansible01
test "$#" -eq 1
MON_FOLLOWUP_SHA=$1
[[ "$MON_FOLLOWUP_SHA" =~ ^[0-9a-f]{40}$ ]]
cd /home/server01_ansible/p1-ans-01
source /home/server01_ansible/.config/ansible/p1-ans-01.env
test -r inventory/hosts.yml
test "${ANSIBLE_DEBUG:-0}" != 1
command -v gh >/dev/null
command -v ansible-playbook >/dev/null
MON_FOLLOWUP_DIR=$(mktemp -d /home/server01_ansible/MON_FOLLOWUP.XXXXXXXX)
printf 'RESULT_DIR=%s\n' "$MON_FOLLOWUP_DIR"
mkdir -p "$MON_FOLLOWUP_DIR/source" "$MON_FOLLOWUP_DIR/results" "$MON_FOLLOWUP_DIR/local-tmp"
printf '%s\n' "$MON_FOLLOWUP_SHA" > "$MON_FOLLOWUP_DIR/source-commit.txt"
for MON_FOLLOWUP_FILE in collect.yml public_inventory.py source-reference.json README.md run.sh; do
  gh api "repos/321Team/infra-monitoring/contents/ops/mon-followup/$MON_FOLLOWUP_FILE?ref=$MON_FOLLOWUP_SHA" \
    -H 'Accept: application/vnd.github.raw+json' > "$MON_FOLLOWUP_DIR/source/$MON_FOLLOWUP_FILE"
done
cmp -- "$0" "$MON_FOLLOWUP_DIR/source/run.sh"
MON_FOLLOWUP_RC=0
ANSIBLE_CONFIG=/home/server01_ansible/p1-ans-01/ansible.cfg \
ANSIBLE_LOCAL_TEMP="$MON_FOLLOWUP_DIR/local-tmp" \
ANSIBLE_DEBUG=0 ANSIBLE_VERBOSITY=0 PYTHONDONTWRITEBYTECODE=1 \
ansible-playbook -i /home/server01_ansible/p1-ans-01/inventory/hosts.yml \
  "$MON_FOLLOWUP_DIR/source/collect.yml" \
  -e "mon_result_dir=$MON_FOLLOWUP_DIR/results" \
  -e '{"ansible_ssh_use_tty":false,"ansible_become":false}' \
  2>&1 | tee "$MON_FOLLOWUP_DIR/run.txt" || MON_FOLLOWUP_RC=$?
if test -s "$MON_FOLLOWUP_DIR/results/k8s-control01.json"; then
  python3 "$MON_FOLLOWUP_DIR/source/public_inventory.py" compare \
    "$MON_FOLLOWUP_DIR/results/k8s-control01.json" "$MON_FOLLOWUP_DIR/source/source-reference.json" \
    > "$MON_FOLLOWUP_DIR/results/comparison.json" || MON_FOLLOWUP_RC=1
else
  MON_FOLLOWUP_RC=1
fi
printf 'COLLECTION_RC=%s\nRUNTIME_CHANGE=NOT_RUN\n' "$MON_FOLLOWUP_RC" > "$MON_FOLLOWUP_DIR/result.txt"
(
  cd "$MON_FOLLOWUP_DIR"
  shopt -s nullglob
  MON_FOLLOWUP_HASH_FILES=(source-commit.txt source/collect.yml source/public_inventory.py
    source/source-reference.json source/README.md source/run.sh run.txt result.txt results/*.json)
  sha256sum "${MON_FOLLOWUP_HASH_FILES[@]}" > SHA256SUMS
)
tar -czf "$MON_FOLLOWUP_DIR.tar.gz" -C "$MON_FOLLOWUP_DIR" \
  source-commit.txt source run.txt result.txt results SHA256SUMS
sha256sum "$MON_FOLLOWUP_DIR.tar.gz" > "$MON_FOLLOWUP_DIR.tar.gz.sha256"
printf 'COLLECTION_RC=%s\nARCHIVE=%s.tar.gz\n' "$MON_FOLLOWUP_RC" "$MON_FOLLOWUP_DIR"
exit "$MON_FOLLOWUP_RC"
