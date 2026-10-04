#!/usr/bin/env bash
# P1-MON-01 #17 approved-terminal port-forward retest - cicd-runner01 side.
# Subcommands: pre | stop | install | place EXP | verify GRAFANA_POD OTHER_POD | pftest GRAFANA_POD
#              | cleanup G0 | restore          (each takes RUN_DIR as the 2nd argument)
# No `set -e`: each step checks its own RC; cleanup and the Restore Gate always decide restart.
SVC=${SVC:-actions.runner.321Team-infra-cicd.cicd-runner01.service}
VER=${VER:-v1.36.4}
DL=${DL:-https://dl.k8s.io/release}
PORT=13000
ROUTE_DST=10.1.93.109
ROUTE_SRC=10.250.10.20
NS=monitoring-api
SA_ID=system:serviceaccount:monitoring-api:p1-mon-pf-verify
SHM=${SHM:-/dev/shm}

cmd=$1
RUN=$2
if [ -z "$cmd" ] || [ -z "$RUN" ]; then
  echo "usage: $0 SUBCOMMAND RUN_DIR [ARGS]" >&2
  exit 2
fi
shift 2
KC="$SHM/p1-mon-pf-verify-$(basename "$RUN").kubeconfig"
KB="$RUN/bin/kubectl"

now() { TZ=Asia/Seoul date '+%F %T %Z'; }
rec() { echo "$1" | tee -a "$RUN/status.txt"; }
st() { grep "^$1=" "$RUN/status.txt" 2>/dev/null | tail -1 | cut -d= -f2-; }
listeners() { ss -Hltn "sport = :$PORT" 2>/dev/null | grep -c .; }
ident() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; echo; awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
alive() { [ -d "/proc/$1" ]; }

do_pre() {
  mkdir -p "$(dirname "$RUN")" && mkdir "$RUN" || { echo "STOP: cannot create $RUN (already exists?)" >&2; return 1; }
  now > "$RUN/00-time.txt"
  getent passwd | grep -v -E '(nologin|false|sync|shutdown|halt)$' | cut -d: -f1,3,7 > "$RUN/01-login-accounts.txt"
  pgrep -a -f 'Runner\.(Listener|Worker)' > "$RUN/02-runner-before.txt" 2>&1
  [ "$(listeners)" = 0 ] || { rec "PRE=STOP_PORT_${PORT}_IN_USE"; return 1; }
  [ -e "$KC" ] && { rec "PRE=STOP_KUBECONFIG_PATH_EXISTS"; return 1; }
  rec "PRE=PASS"
}

do_stop() {
  sudo systemctl stop "$SVC"
  local rc=$? a
  a=$(systemctl is-active "$SVC")
  echo "stop_rc=$rc is-active=$a" > "$RUN/03-runner-stop.txt"
  pgrep -a -f 'Runner\.(Listener|Worker)' >> "$RUN/03-runner-stop.txt" 2>&1
  if [ "$rc" -eq 0 ] && [ "$a" = inactive ] && [ "$(pgrep -f 'Runner\.(Listener|Worker)' | grep -c .)" = 0 ]; then
    rec "RUNNER_STOPPED_LOCAL=PASS"; return 0
  fi
  rec "RUNNER_STOPPED_LOCAL=FAIL"; return 1
}

do_install() {
  mkdir "$RUN/bin" || { rec "KUBECTL_INSTALLED=FAIL_BINDIR"; return 1; }
  (
    cd "$RUN/bin" || exit 10
    curl -fsSLo kubectl "$DL/$VER/bin/linux/amd64/kubectl" || exit 11
    curl -fsSLo kubectl.sha256 "$DL/$VER/bin/linux/amd64/kubectl.sha256" || exit 12
    printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum --check > "$RUN/04-kubectl-sha.txt" 2>&1
    c=$?
    echo "CHECKSUM_RC=$c" >> "$RUN/04-kubectl-sha.txt"
    [ "$c" -eq 0 ] || exit 13
    chmod 700 kubectl || exit 14
    ./kubectl version --client >> "$RUN/04-kubectl-sha.txt" 2>&1 || exit 15
  )
  local rc=$?
  if [ "$rc" -eq 0 ]; then rec "KUBECTL_INSTALLED=PASS"; return 0; fi
  rm -f "$RUN/bin/kubectl" "$RUN/bin/kubectl.sha256"
  rec "KUBECTL_INSTALLED=FAIL_RC_$rc"
  return 1
}

# Reads the kubeconfig from stdin (paste, then Ctrl-D). Stdin is not stored in shell history.
do_place() {
  local exp=$1
  case "$exp" in ''|*[^0-9]*) rec "KUBECONFIG_PLACED=STOP_BAD_EXP"; return 1 ;; esac
  [ -e "$KC" ] && { rec "KUBECONFIG_PLACED=STOP_EXISTS"; return 1; }
  ( umask 077; cat > "$KC" )
  if [ -s "$KC" ] && grep -q 'token:' "$KC" && [ "$(stat -c %a "$KC")" = 600 ]; then
    echo "TOKEN_EXP=$exp" >> "$RUN/status.txt"
    ls -l "$KC" > "$RUN/05-kubeconfig-perm.txt"
    rec "KUBECONFIG_PLACED=PASS"; return 0
  fi
  rm -f "$KC"
  rec "KUBECONFIG_PLACED=FAIL"; return 1
}

do_verify() {
  local gp=$1 op=$2 out bad=0 c want got
  [ -n "$gp" ] && [ -n "$op" ] || { rec "AUTHZ=STOP_ARGS"; return 1; }
  ip -4 route get "$ROUTE_DST" > "$RUN/06-route.txt" 2>&1
  grep -q "src $ROUTE_SRC" "$RUN/06-route.txt" && rec "ROUTE_SRC_10.250.10.20=PASS" || { rec "ROUTE_SRC_10.250.10.20=FAIL"; bad=1; }
  out=$("$KB" --kubeconfig "$KC" auth whoami 2>&1)
  echo "$out" > "$RUN/07-whoami.txt"
  echo "$out" | grep -q "$SA_ID" && rec "AUTH_IDENTITY_EXPECTED=PASS" || { rec "AUTH_IDENTITY_EXPECTED=FAIL"; bad=1; }
  : > "$RUN/08-can-i.txt"
  while IFS='|' read -r key want c; do
    got=$("$KB" --kubeconfig "$KC" -n "$NS" auth can-i $c 2>&1 < /dev/null)
    echo "$c => $got (expect $want)" >> "$RUN/08-can-i.txt"
    if [ "$got" = "$want" ]; then rec "$key=PASS"; else rec "$key=FAIL"; bad=1; fi
  done <<EOF
AUTHORIZED_EXACT_POD_GET|yes|get pods/$gp
AUTHORIZED_EXACT_POD_PORTFORWARD|yes|create pods/$gp --subresource=portforward
DENY_POD_LIST|no|list pods
DENY_SECRET_GET|no|get secrets
DENY_OTHER_POD_GET|no|get pods/$op
DENY_OTHER_POD_PORTFORWARD|no|create pods/$op --subresource=portforward
EOF
  [ "$bad" = 0 ] && { rec "AUTHZ=PASS"; return 0; }
  rec "AUTHZ=FAIL"; return 1
}

# Identity: exact cmdline+starttime recorded once the forward is ready (after exec). Before that,
# only a process whose cmdline is this run's port-forward with this run's kubeconfig is ours.
ours() {
  if [ -f "$RUN/pf.ident" ]; then
    [ "$(ident "$1")" = "$(cat "$RUN/pf.ident")" ]
  else
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -F -q -- "$KC" &&
      tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q 'port-forward'
  fi
}

stop_pf() {
  if [ -f "$RUN/pf.pid" ]; then :; else rec "PF_PROCESS_STOPPED=NOT_STARTED"; return 0; fi
  local pid i
  pid=$(cat "$RUN/pf.pid")
  if alive "$pid"; then
    if ours "$pid"; then
      kill -TERM "$pid" 2>/dev/null
      for i in 1 2 3 4 5 6 7 8 9 10; do alive "$pid" || break; sleep 0.5; done
      alive "$pid" && kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
    else
      rec "PF_PROCESS_STOPPED=FAIL_IDENTITY_MISMATCH"; return 1
    fi
  fi
  for i in 1 2 3 4 5 6; do alive "$pid" || break; sleep 0.5; done
  alive "$pid" && { rec "PF_PROCESS_STOPPED=FAIL_ALIVE"; return 1; }
  for i in 1 2 3 4 5 6; do [ "$(listeners)" = 0 ] && break; sleep 0.5; done
  [ "$(listeners)" = 0 ] || { rec "PF_PROCESS_STOPPED=FAIL_LISTENER"; return 1; }
  rec "PF_PROCESS_STOPPED=PASS"
}

do_pftest() {
  local gp=$1 pid i ready=0 code rc
  [ -n "$gp" ] || { rec "PF=STOP_ARGS"; return 1; }
  [ "$(listeners)" = 0 ] || { rec "PF=STOP_PORT_${PORT}_IN_USE"; return 1; }
  "$KB" --kubeconfig "$KC" -n "$NS" port-forward --address=127.0.0.1 "pod/$gp" "$PORT:3000" > "$RUN/09-pf.log" 2>&1 &
  pid=$!
  echo "$pid" > "$RUN/pf.pid"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if alive "$pid" && grep -q "Forwarding from 127.0.0.1:$PORT" "$RUN/09-pf.log"; then ready=1; break; fi
    alive "$pid" || break
    sleep 0.5
  done
  if [ "$ready" = 0 ]; then rec "PF_START=FAIL"; stop_pf; return 1; fi
  ident "$pid" > "$RUN/pf.ident"
  rec "PF_START=PASS"
  code=$(curl -sS --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/health" 2>>"$RUN/10-http.err")
  rc=$?; echo "health code=$code rc=$rc" >> "$RUN/10-http.txt"
  [ "$rc" -eq 0 ] && [ "$code" = 200 ] && rec "GRAFANA_HEALTH_200=PASS" || rec "GRAFANA_HEALTH_200=FAIL"
  code=$(curl -sS --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/search" 2>>"$RUN/10-http.err")
  rc=$?; echo "search_noauth code=$code rc=$rc" >> "$RUN/10-http.txt"
  [ "$rc" -eq 0 ] && [ "$code" = 401 ] && rec "GRAFANA_UNAUTH_401=PASS" || rec "GRAFANA_UNAUTH_401=FAIL"
  stop_pf
  [ "$(st GRAFANA_HEALTH_200)" = PASS ] && [ "$(st GRAFANA_UNAUTH_401)" = PASS ] && [ "$(st PF_PROCESS_STOPPED)" = PASS ]
}

# G0 = control01 result of `pf_cp.sh delete` (TEMP_OBJECTS_REMOVED value), typed from that screen.
do_cleanup() {
  local g0=$1 g1 g2 g3 gpf out rc exp nowe
  stop_pf
  gpf=$(st PF_PROCESS_STOPPED)
  if [ "$(st KUBECONFIG_PLACED)" = PASS ]; then
    if [ -e "$KC" ] && [ -x "$KB" ]; then
      out=$("$KB" --kubeconfig "$KC" auth whoami 2>&1); rc=$?
      printf '%s\nrc=%s\n' "$out" "$rc" > "$RUN/12-old-token-after-sa-delete.txt"
      exp=$(st TOKEN_EXP); nowe=$(date +%s)
      if [ "$rc" -ne 0 ] && echo "$out" | grep -q -i unauthorized; then
        if [ "$nowe" -lt "$exp" ]; then g1=DENIED; else g1=EXPIRED_NOT_PROVEN; fi
      else
        g1=NOT_DENIED
      fi
    else
      g1=NOT_VERIFIED_FILE_OR_TOOL_MISSING
    fi
  else
    g1=NOT_TRANSFERRED
  fi
  rec "OLD_TOKEN_AUTH_AFTER_SA_DELETE=$g1"
  rm -f "$KC"
  if [ -e "$KC" ]; then g2=FAIL; elif [ "$g1" = NOT_TRANSFERRED ]; then g2=NOT_TRANSFERRED; else g2=PASS; fi
  rec "KUBECONFIG_REMOVED=$g2"
  if [ -e "$RUN/bin" ]; then rm -f "$RUN/bin/kubectl" "$RUN/bin/kubectl.sha256"; fi
  if [ -e "$KB" ]; then g3=FAIL; elif [ "$(st KUBECTL_INSTALLED)" = PASS ]; then g3=PASS; else g3=NOT_INSTALLED; fi
  rec "TEST_KUBECTL_REMOVED=$g3"
  rec "TEMP_OBJECTS_REMOVED_CP=$g0"
  local ok=1
  case "$g0" in PASS|NOT_CREATED) ;; *) ok=0 ;; esac
  case "$gpf" in PASS|NOT_STARTED) ;; *) ok=0 ;; esac
  case "$g1" in DENIED|EXPIRED_NOT_PROVEN|NOT_TRANSFERRED) ;; *) ok=0 ;; esac
  case "$g2" in PASS|NOT_TRANSFERRED) ;; *) ok=0 ;; esac
  case "$g3" in PASS|NOT_INSTALLED) ;; *) ok=0 ;; esac
  if [ "$ok" = 1 ]; then rec "RESTORE_GATE=PASS"; return 0; fi
  rec "RESTORE_GATE=BLOCKED"
  rec "RUNNER_RESTORED=NOT_RUN"
  return 1
}

do_restore() {
  [ "$(st RESTORE_GATE)" = PASS ] || { rec "RUNNER_RESTORED=REFUSED_GATE_NOT_PASS"; return 1; }
  sudo systemctl start "$SVC"
  local rc=$? a i
  for i in 1 2 3 4 5 6; do a=$(systemctl is-active "$SVC"); [ "$a" = active ] && break; sleep 0.5; done
  echo "start_rc=$rc is-active=$a" > "$RUN/13-runner-restore.txt"
  pgrep -a -f 'Runner\.Listener' >> "$RUN/13-runner-restore.txt" 2>&1
  if [ "$rc" -eq 0 ] && [ "$a" = active ] && [ "$(pgrep -f 'Runner\.Listener' | grep -c .)" -ge 1 ]; then
    rec "RUNNER_RESTORED_LOCAL=PASS"; return 0
  fi
  rec "RUNNER_RESTORED_LOCAL=FAIL"; return 1
}

case "$cmd" in
  pre) do_pre ;;
  stop) do_stop ;;
  install) do_install ;;
  place) do_place "$1" ;;
  verify) do_verify "$1" "$2" ;;
  pftest) do_pftest "$1" ;;
  cleanup) do_cleanup "$1" ;;
  restore) do_restore ;;
  *) echo "unknown subcommand: $cmd" >&2; exit 2 ;;
esac
