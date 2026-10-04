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
case "$RUN" in /*) ;; *) RUN="$PWD/$RUN" ;; esac
KC="$SHM/p1-mon-pf-verify-$(basename "$RUN").kubeconfig"
KB="$RUN/bin/kubectl"

now() { TZ=Asia/Seoul date '+%F %T %Z'; }
rec() { echo "$1" | tee -a "$RUN/status.txt"; }
st() { grep "^$1=" "$RUN/status.txt" 2>/dev/null | tail -1 | cut -d= -f2-; }
# Prints the number of listeners on PORT, or UNKNOWN when ss itself failed (output and RC kept in ss.log).
listeners() {
  local out rc
  out=$(ss -Hltn "sport = :$PORT" 2>>"$RUN/ss.err")
  rc=$?
  printf '%s rc=%s\n%s\n' "$(now)" "$rc" "$out" >> "$RUN/ss.log"
  if [ "$rc" -ne 0 ]; then echo UNKNOWN; return; fi
  printf '%s\n' "$out" | grep -c .
}
ident() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; echo; awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
alive() { [ -d "/proc/$1" ]; }
cmdline_of() { local a; mapfile -d '' a < "/proc/$1/cmdline" 2>/dev/null || return 1; echo "${a[*]}"; }
# Live port-forward processes started with this run's kubeconfig, found without relying on pf.pid.
own_pids() {
  local d c
  for d in /proc/[0-9]*; do
    c=$(cmdline_of "${d#/proc/}") || continue
    case "$c" in *"--kubeconfig $KC "*"port-forward"*) echo "${d#/proc/}" ;; esac
  done
}
# Steps that handle the credential or reach the cluster need a stopped runner and a run not yet cleaned.
phase_ok() {
  [ "$(st RUNNER_STOPPED_LOCAL)" = PASS ] || { rec "$1=STOP_RUNNER_NOT_STOPPED"; return 1; }
  [ -z "$(st CLEANUP_STARTED)" ] || { rec "$1=STOP_CLEANUP_ALREADY_STARTED"; return 1; }
}

do_pre() {
  mkdir -p "$(dirname "$RUN")" && mkdir "$RUN" || { echo "STOP: cannot create $RUN (already exists?)" >&2; return 1; }
  now > "$RUN/00-time.txt"
  getent passwd | grep -v -E '(nologin|false|sync|shutdown|halt)$' | cut -d: -f1,3,7 > "$RUN/01-login-accounts.txt"
  pgrep -a -f 'Runner\.(Listener|Worker)' > "$RUN/02-runner-before.txt" 2>&1
  local l
  l=$(listeners)
  [ "$l" = UNKNOWN ] && { rec "PRE=STOP_LISTENER_UNKNOWN"; return 1; }
  [ "$l" = 0 ] || { rec "PRE=STOP_PORT_${PORT}_IN_USE"; return 1; }
  [ -e "$KC" ] && { rec "PRE=STOP_KUBECONFIG_PATH_EXISTS"; return 1; }
  rec "PRE=PASS"
}

do_stop() {
  [ "$(st PRE)" = PASS ] || { rec "RUNNER_STOPPED_LOCAL=STOP_PRE_NOT_PASS"; return 1; }
  [ -z "$(st CLEANUP_STARTED)" ] || { rec "RUNNER_STOPPED_LOCAL=STOP_CLEANUP_ALREADY_STARTED"; return 1; }
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
  phase_ok INSTALL || return 1
  mkdir "$RUN/bin" || { rec "KUBECTL_INSTALLED=FAIL_BINDIR"; return 1; }
  (
    cd "$RUN/bin" || exit 10
    curl -fsSL --connect-timeout 10 --max-time 300 -o kubectl "$DL/$VER/bin/linux/amd64/kubectl" || exit 11
    curl -fsSL --connect-timeout 10 --max-time 60 -o kubectl.sha256 "$DL/$VER/bin/linux/amd64/kubectl.sha256" || exit 12
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
# PLACE_STARTED is recorded before the write, so an interrupted write is never read as "not transferred".
do_place() {
  local exp=$1 rc
  case "$exp" in ''|*[^0-9]*) rec "PLACE=STOP_BAD_EXP"; return 1 ;; esac
  phase_ok PLACE || return 1
  [ -z "$(st PLACE_STARTED)" ] || { rec "PLACE=STOP_ALREADY_STARTED"; return 1; }
  [ -e "$KC" ] && { rec "PLACE=STOP_EXISTS"; return 1; }
  rec "TOKEN_EXP=$exp"
  rec "PLACE_STARTED=$(now)"
  ( umask 077; cat > "$KC" )
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$KC" ] && grep -q 'token:' "$KC" && [ "$(stat -c %a "$KC")" = 600 ]; then
    ls -l "$KC" > "$RUN/05-kubeconfig-perm.txt"
    rec "KUBECONFIG_PLACED=PASS"; return 0
  fi
  echo "write_rc=$rc" > "$RUN/05-kubeconfig-place-fail.txt"
  rm -f "$KC"
  if [ -e "$KC" ]; then rec "KUBECONFIG_PLACED=FAIL_NOT_REMOVED"; return 1; fi
  if [ "$rc" -ne 0 ]; then rec "KUBECONFIG_PLACED=FAIL_WRITE_REMOVED"; else rec "KUBECONFIG_PLACED=FAIL_INVALID_REMOVED"; fi
  return 1
}

do_verify() {
  local gp=$1 op=$2 out bad=0 c want got
  [ -n "$gp" ] && [ -n "$op" ] || { rec "AUTHZ=STOP_ARGS"; return 1; }
  phase_ok AUTHZ || return 1
  [ "$(st KUBECONFIG_PLACED)" = PASS ] || { rec "AUTHZ=STOP_NOT_PLACED"; return 1; }
  ip -4 route get "$ROUTE_DST" > "$RUN/06-route.txt" 2>&1
  grep -q "src $ROUTE_SRC" "$RUN/06-route.txt" && rec "ROUTE_SRC_10.250.10.20=PASS" || { rec "ROUTE_SRC_10.250.10.20=FAIL"; bad=1; }
  out=$("$KB" --kubeconfig "$KC" --request-timeout=15s auth whoami 2>&1)
  echo "$out" > "$RUN/07-whoami.txt"
  echo "$out" | grep -q "$SA_ID" && rec "AUTH_IDENTITY_EXPECTED=PASS" || { rec "AUTH_IDENTITY_EXPECTED=FAIL"; bad=1; }
  : > "$RUN/08-can-i.txt"
  while IFS='|' read -r key want c; do
    got=$("$KB" --kubeconfig "$KC" --request-timeout=15s -n "$NS" auth can-i $c 2>&1 < /dev/null)
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
    case "$(cmdline_of "$1")" in *"--kubeconfig $KC "*"port-forward"*) return 0 ;; esac
    return 1
  fi
}

kill_wait() {
  local i
  kill -TERM "$1" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do alive "$1" || break; sleep 0.5; done
  alive "$1" && kill -KILL "$1" 2>/dev/null
  wait "$1" 2>/dev/null
  for i in 1 2 3 4 5 6; do alive "$1" || break; sleep 0.5; done
}

# Stops only processes proven to be this run's port-forward. A listener that is not ours is never
# killed; it, or an unreadable listener table, blocks the result instead.
stop_pf() {
  local pid p i l launched
  launched=$(st PF_LAUNCH)
  if [ -f "$RUN/pf.pid" ]; then
    pid=$(cat "$RUN/pf.pid")
    if alive "$pid"; then
      if ours "$pid"; then kill_wait "$pid"; else rec "PF_PROCESS_STOPPED=FAIL_IDENTITY_MISMATCH"; return 1; fi
    fi
    alive "$pid" && { rec "PF_PROCESS_STOPPED=FAIL_ALIVE"; return 1; }
  fi
  for p in $(own_pids); do kill_wait "$p"; done
  [ -n "$(own_pids)" ] && { rec "PF_PROCESS_STOPPED=FAIL_OWN_PROCESS_ALIVE"; return 1; }
  for i in 1 2 3 4 5 6; do
    l=$(listeners)
    if [ "$l" = 0 ] || [ "$l" = UNKNOWN ]; then break; fi
    sleep 0.5
  done
  case "$l" in
    0) ;;
    UNKNOWN) rec "PF_PROCESS_STOPPED=FAIL_LISTENER_UNKNOWN"; return 1 ;;
    *) if [ -z "$launched" ]; then rec "PF_PROCESS_STOPPED=FAIL_FOREIGN_LISTENER"; else rec "PF_PROCESS_STOPPED=FAIL_LISTENER"; fi
       return 1 ;;
  esac
  if [ -z "$launched" ]; then rec "PF_PROCESS_STOPPED=NOT_STARTED"; else rec "PF_PROCESS_STOPPED=PASS"; fi
}

do_pftest() {
  local gp=$1 pid i ready=0 code rc l
  [ -n "$gp" ] || { rec "PF=STOP_ARGS"; return 1; }
  phase_ok PF || return 1
  [ "$(st AUTHZ)" = PASS ] || { rec "PF=STOP_AUTHZ_NOT_PASS"; return 1; }
  [ -z "$(st PF_LAUNCH)" ] || { rec "PF=STOP_ALREADY_LAUNCHED"; return 1; }
  l=$(listeners)
  [ "$l" = UNKNOWN ] && { rec "PF=STOP_LISTENER_UNKNOWN"; return 1; }
  [ "$l" = 0 ] || { rec "PF=STOP_PORT_${PORT}_IN_USE"; return 1; }
  rec "PF_LAUNCH=$(now)"
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
# Once started the run is closed: stop/install/place/verify/pftest refuse, and any earlier gate is void.
do_cleanup() {
  local g0=$1 g1 g2 g3 gpf out rc exp nowe placed started
  rec "CLEANUP_STARTED=$(now)"
  rec "RESTORE_GATE=RESET"
  stop_pf
  gpf=$(st PF_PROCESS_STOPPED)
  started=$(st PLACE_STARTED)
  placed=$(st KUBECONFIG_PLACED)
  if [ -z "$started" ]; then
    if [ -e "$KC" ]; then g1=UNKNOWN_FILE_WITHOUT_PLACE; else g1=NOT_TRANSFERRED; fi
  elif [ "$placed" = PASS ]; then
    if [ -e "$KC" ] && [ -x "$KB" ]; then
      out=$("$KB" --kubeconfig "$KC" --request-timeout=15s auth whoami 2>&1); rc=$?
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
    # Started but not completed: only an explicit failure whose file was removed is known.
    case "$placed" in
      FAIL_WRITE_REMOVED|FAIL_INVALID_REMOVED) g1=PLACE_FAILED_FILE_REMOVED ;;
      *) g1=PLACE_INTERRUPTED ;;
    esac
  fi
  rec "OLD_TOKEN_AUTH_AFTER_SA_DELETE=$g1"
  # A file at this run's path without a recorded placement is not proven ours; leave it and block.
  if [ "$g1" = UNKNOWN_FILE_WITHOUT_PLACE ]; then
    g2=FAIL_UNOWNED_FILE
  else
    rm -f "$KC"
    if [ -e "$KC" ]; then g2=FAIL; elif [ "$g1" = NOT_TRANSFERRED ]; then g2=NOT_TRANSFERRED; else g2=PASS; fi
  fi
  rec "KUBECONFIG_REMOVED=$g2"
  if [ -e "$RUN/bin" ]; then rm -f "$RUN/bin/kubectl" "$RUN/bin/kubectl.sha256"; fi
  if [ -e "$KB" ]; then g3=FAIL; elif [ "$(st KUBECTL_INSTALLED)" = PASS ]; then g3=PASS; else g3=NOT_INSTALLED; fi
  rec "TEST_KUBECTL_REMOVED=$g3"
  rec "TEMP_OBJECTS_REMOVED_CP=$g0"
  local ok=1
  case "$g0" in PASS|NOT_CREATED) ;; *) ok=0 ;; esac
  case "$gpf" in PASS|NOT_STARTED) ;; *) ok=0 ;; esac
  case "$g1" in DENIED|EXPIRED_NOT_PROVEN|NOT_TRANSFERRED|PLACE_FAILED_FILE_REMOVED) ;; *) ok=0 ;; esac
  case "$g2" in PASS|NOT_TRANSFERRED) ;; *) ok=0 ;; esac
  case "$g3" in PASS|NOT_INSTALLED) ;; *) ok=0 ;; esac
  if [ "$ok" = 1 ]; then rec "RESTORE_GATE=PASS"; return 0; fi
  rec "RESTORE_GATE=BLOCKED"
  rec "RUNNER_RESTORED=NOT_RUN"
  return 1
}

# Re-checked right before restart, independent of the recorded gate.
residual() {
  local r="" l
  [ -e "$KC" ] && r="${r}kubeconfig,"
  [ -e "$KB" ] && r="${r}kubectl,"
  [ -n "$(own_pids)" ] && r="${r}pf_process,"
  l=$(listeners)
  [ "$l" = 0 ] || r="${r}listener_$l,"
  echo "${r%,}"
}

do_restore() {
  [ -n "$(st CLEANUP_STARTED)" ] || { rec "RUNNER_RESTORED=REFUSED_NO_CLEANUP"; return 1; }
  [ "$(st RESTORE_GATE)" = PASS ] || { rec "RUNNER_RESTORED=REFUSED_GATE_NOT_PASS"; return 1; }
  local r
  r=$(residual)
  [ -z "$r" ] || { rec "RUNNER_RESTORED=REFUSED_RESIDUAL_$r"; return 1; }
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
