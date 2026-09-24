#!/usr/bin/env bash
# One-shot monitor01 console reader; no download, installation or service change.
set -euo pipefail
umask 077
test "$(hostname -s)" = monitor01
ip -o -4 address show | awk '$4 ~ /^10[.]250[.]10[.]30\// { found=1 } END { exit !found }'
MON_INPUT_DIR=$(mktemp -d "$HOME/MON_HOST_INPUTS.XXXXXXXX")
printf 'RESULT_DIR=%s\n' "$MON_INPUT_DIR"
cp -- "$0" "$MON_INPUT_DIR/collector.sh"
MON_FAILED=0
mon_read() {
  local label=$1 rc=0
  shift
  timeout 20 "$@" > "$MON_INPUT_DIR/$label.txt" 2> "$MON_INPUT_DIR/$label.stderr.txt" || rc=$?
  printf '%s\t%s\n' "$label" "$rc" >> "$MON_INPUT_DIR/checks.tsv"
  if test "$rc" -ne 0; then MON_FAILED=$((MON_FAILED + 1)); fi
}
date -Is > "$MON_INPUT_DIR/started-at.txt"
printf 'READ_ONLY=YES\nREFERENCE_COLLECTOR=9746f521612669572adeb8749f6afaaf0a256cbe\n' > "$MON_INPUT_DIR/scope.txt"
mon_read identity hostname -s
mon_read account id
mon_read addresses ip -br -4 address
mon_read listeners ss -H -lnt
mon_read services systemctl show nginx.service prometheus.service blackbox-exporter.service docker.service podman.service cockpit.socket --property=Id,LoadState,ActiveState,SubState,UnitFileState,User,Group,MainPID
mon_read capacity df -P / /var/lib /home/server01_monitor
mon_read selinux getenforce
for MON_PEER in 10.1.93.105 10.1.93.107 10.1.93.108 10.250.10.10; do
  mon_read "route-$MON_PEER" ip -4 route get "$MON_PEER"
done
mon_read leaf-metadata sudo -n stat --printf='%F|%a|%u|%g|%C\n' -- /home/server01_monitor/monitor01.crt
mon_read root-metadata sudo -n stat --printf='%F|%a|%u|%g|%C\n' -- /home/server01_monitor/fds-root-ca.crt
mon_read key-metadata sudo -n stat --printf='%F|%a|%u|%g|%C\n' -- /etc/fds/pki/monitor01/request/monitor01.key
mon_read docker sudo -n docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}'
mon_read podman sudo -n podman ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}'
date -Is > "$MON_INPUT_DIR/finished-at.txt"
printf 'CHECKS=16\nNONZERO_CHECKS=%s\nRUNTIME_CHANGE=NOT_RUN\n' "$MON_FAILED" > "$MON_INPUT_DIR/result.txt"
(
  cd "$MON_INPUT_DIR"
  sha256sum collector.sh checks.tsv ./*.txt > SHA256SUMS
)
tar -czf "$MON_INPUT_DIR.tar.gz" -C "$MON_INPUT_DIR" .
sha256sum "$MON_INPUT_DIR.tar.gz" > "$MON_INPUT_DIR.tar.gz.sha256"
printf 'NONZERO_CHECKS=%s\nARCHIVE=%s.tar.gz\nSIDECAR=%s.tar.gz.sha256\n' "$MON_FAILED" "$MON_INPUT_DIR" "$MON_INPUT_DIR"
# Missing tools, paths and sudo access are findings; archive is retained on partial reads.
test "$MON_FAILED" -eq 0
