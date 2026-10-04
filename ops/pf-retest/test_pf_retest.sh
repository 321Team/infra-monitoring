#!/usr/bin/env bash
# Offline MOCK tests for ops/pf-retest (no cluster, no network, no sudo).
# Fake kubectl/curl/systemctl/sudo/pgrep/ss/ip/getent are generated per scenario.
# Usage: bash ops/pf-retest/test_pf_retest.sh
HERE=$(cd "$(dirname "$0")" && pwd)
ORIG_PATH=$PATH
REAL_CAT=$(command -v cat)
T=$(mktemp -d)
BG=""
finish() { for p in $BG; do kill -KILL "$p" 2>/dev/null; done; rm -rf "$T"; }
trap finish EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1"; fi; }
stv() { grep "^$2=" "$1/status.txt" 2>/dev/null | tail -1 | cut -d= -f2-; }

write_mocks() { # $1 = bin dir
  local B=$1
  cat > "$B/kubectl" <<'MOCK'
#!/usr/bin/env bash
S=$MOCK_STATE
a="$*"
echo "$a" >> "$S/kubectl.calls"
obj() { case "$a" in *" serviceaccount "*) echo serviceaccount ;; *" rolebinding "*) echo rolebinding ;; *" role "*) echo role ;; esac; }
case "$a" in
  *"version --client"*) touch "$S/kubectl_executed"; echo "Client Version: v1.36.4"; exit 0 ;;
  *"config current-context"*) echo kubernetes-admin@kubernetes; exit 0 ;;
  *"port-forward"*)
    if [ -n "$MOCK_PF_FAIL" ]; then echo "error: unable to listen on any of the requested ports"; exit 1; fi
    touch "$S/listen13000"
    trap 'rm -f "$S/listen13000"; exit 0' TERM INT
    echo "Forwarding from 127.0.0.1:13000 -> 3000"
    while :; do sleep 0.2; done ;;
  *"auth whoami"*)
    case "$a" in
      *"--kubeconfig="*) printf 'ATTRIBUTE VALUE\nUsername kubernetes-admin\nGroups [kubeadm:cluster-admins system:authenticated]\n'; exit 0 ;;
    esac
    if [ -n "$MOCK_TOKEN_STILL_VALID" ] || [ -f "$S/obj_serviceaccount" ]; then
      echo "Username system:serviceaccount:monitoring-api:p1-mon-pf-verify"; exit 0
    fi
    echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1 ;;
  *"auth can-i"*)
    case "$a" in
      *"get pods/$MOCK_GRAFANA"|*"create pods/$MOCK_GRAFANA --subresource=portforward") echo yes; exit 0 ;;
      *"list pods") if [ -n "$MOCK_CANI_WIDE" ]; then echo yes; exit 0; fi ;;
    esac
    echo no; exit 1 ;;
  *"get pods -o wide"*) echo "NAME READY STATUS"; echo "$MOCK_GRAFANA 1/1 Running"; exit 0 ;;
  *"get pod -l app=grafana"*) echo "$MOCK_GRAFANA"; exit 0 ;;
  *"get pod -l app=prometheus"*) echo "prometheus-abc"; exit 0 ;;
  *"get pod $MOCK_GRAFANA "*)
    uid=uid-g1; [ -f "$S/pod_uid" ] && uid=$(cat "$S/pod_uid")
    printf '%s %s ready=true' "$MOCK_GRAFANA" "$uid"; exit 0 ;;
  *"get svc grafana"*) printf ClusterIP; exit 0 ;;
  *"get ingress -A -o json"*) echo '{"items":[]}'; exit 0 ;;
  *" get serviceaccount p1-mon-pf-verify"*|*" get role p1-mon-pf-verify"*|*" get rolebinding p1-mon-pf-verify"*)
    k=$(obj)
    if [ -n "$MOCK_GET_FORBIDDEN" ]; then echo "Error from server (Forbidden): $k" >&2; exit 1; fi
    if [ -f "$S/obj_$k" ]; then printf '%s' "$(cat "$S/obj_$k")"; exit 0; fi
    echo "Error from server (NotFound): $k \"p1-mon-pf-verify\" not found" >&2; exit 1 ;;
  *"create --dry-run=server -f"*)
    if [ -n "$MOCK_DRYRUN_FAIL" ]; then echo "error: admission webhook denied"; exit 1; fi
    echo "serviceaccount/p1-mon-pf-verify created (server dry run)"; exit 0 ;;
  *"create -f"*)
    case "$a" in
      *08-sa.yaml*) k=serviceaccount; u=uid-sa ;;
      *08-rolebinding.yaml*) k=rolebinding; u=uid-rb ;;
      *08-role.yaml*) k=role; u=uid-role ;;
      *) echo "mock: unexpected create: $a" >&2; exit 98 ;;
    esac
    if [ -n "$MOCK_CREATE_PARTIAL" ] && [ "$k" != serviceaccount ]; then echo "Error from server (Forbidden): $k is forbidden" >&2; exit 1; fi
    echo "$u" > "$S/obj_$k"
    # Created on the server but the response never reached the client.
    if [ "$MOCK_CREATE_LOST" = "$k" ]; then echo "error: the server was unable to return a response in the time allotted" >&2; exit 1; fi
    # Same-name object replaced right after our create returned.
    if [ "$MOCK_REPLACE_AFTER" = "$k" ]; then echo uid-replacement > "$S/obj_$k"; fi
    printf '%s' "$u"; exit 0 ;;
  *"create token"*)
    if [ -n "$MOCK_TOKEN_FAIL" ]; then echo "error: token request failed" >&2; exit 1; fi
    if [ -n "$MOCK_JWT_BAD" ]; then echo "not-a-jwt"; exit 0; fi
    now=$(date +%s); ttl=${MOCK_TTL:-600}
    b64() { base64 | tr -d '\n=' | tr '+/' '-_'; }
    h=$(printf '{"alg":"RS256"}' | b64)
    p=$(printf '{"sub":"system:serviceaccount:monitoring-api:p1-mon-pf-verify","aud":["https://kubernetes.default.svc"],"iat":%s,"exp":%s}' "$now" "$((now + ttl))" | b64)
    echo "$h.$p.c2ln"; exit 0 ;;
  *"delete --raw="*)
    body=$(cat)
    if [ -n "$MOCK_DELETE_FAIL" ]; then echo "Error from server (InternalError)"; exit 1; fi
    case "$a" in *"/serviceaccounts/"*) k=serviceaccount ;; *"/rolebindings/"*) k=rolebinding ;; *"/roles/"*) k=role ;; esac
    want=$(echo "$body" | sed -n 's/.*"uid":"\([^"]*\)".*/\1/p')
    if [ -f "$S/obj_$k" ] && [ "$(cat "$S/obj_$k")" = "$want" ]; then rm -f "$S/obj_$k"; echo deleted; exit 0; fi
    echo "Error from server (Conflict): precondition failed"; exit 1 ;;
esac
echo "mock kubectl: unhandled: $a" >&2
exit 99
MOCK
  cat > "$B/curl" <<'MOCK'
#!/usr/bin/env bash
S=$MOCK_STATE; out=""; url=""; w=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w) w=$2; shift 2 ;;
    --*) shift ;;
    -*o) out=$2; shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *dl.k8s.io*)
    if [ -n "$MOCK_DL_FAIL" ]; then echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; fi
    case "$url" in
      *.sha256) if [ -n "$MOCK_SHA_BAD" ]; then printf '%064d' 0 > "$out"; else sha256sum "$MOCK_BIN/kubectl" | cut -d' ' -f1 | tr -d '\n' > "$out"; fi ;;
      *) cp "$MOCK_BIN/kubectl" "$out" ;;
    esac
    exit 0 ;;
  *127.0.0.1:13000*)
    if [ -n "$MOCK_HTTP_HANG" ]; then echo $$ >> "$S/hang.pids"; sleep 60; fi
    if [ -n "$MOCK_HTTP_TIMEOUT" ]; then printf 000; echo "curl: (28) Operation timed out" >&2; exit 28; fi
    [ -f "$S/listen13000" ] || { printf 000; exit 7; }
    case "$url" in *api/health) printf 200 ;; *api/search) printf 401 ;; esac
    exit 0 ;;
esac
exit 6
MOCK
  cat > "$B/systemctl" <<'MOCK'
#!/usr/bin/env bash
S=$MOCK_STATE
case "$1" in
  stop) [ -n "$MOCK_STOP_FAIL" ] && exit 1; rm -f "$S/runner_active"; exit 0 ;;
  start) touch "$S/runner_active"; exit 0 ;;
  is-active) if [ -f "$S/runner_active" ]; then echo active; exit 0; fi; echo inactive; exit 3 ;;
esac
exit 1
MOCK
  cat > "$B/sudo" <<'MOCK'
#!/usr/bin/env bash
while [ "${1#-}" != "$1" ]; do shift; done
exec "$@"
MOCK
  cat > "$B/pgrep" <<'MOCK'
#!/usr/bin/env bash
S=$MOCK_STATE
all="$*"
if [ -f "$S/runner_active" ]; then
  case "$all" in *-a*) echo "1234 /home/server01_cicd-runner/actions-runner/bin/Runner.Listener run --startuptype service" ;; *) echo 1234 ;; esac
  exit 0
fi
exit 1
MOCK
  cat > "$B/ss" <<'MOCK'
#!/usr/bin/env bash
if [ -n "$MOCK_SS_FAIL" ]; then echo "Cannot open netlink socket: Operation not permitted" >&2; exit 1; fi
[ -f "$MOCK_STATE/listen13000" ] && echo "LISTEN 0 4096 127.0.0.1:13000 0.0.0.0:*"
exit 0
MOCK
  cat > "$B/ip" <<'MOCK'
#!/usr/bin/env bash
echo "10.1.93.109 via 10.250.10.1 dev ens160 src ${MOCK_SRC:-10.250.10.20} uid 1000"
MOCK
  cat > "$B/getent" <<'MOCK'
#!/usr/bin/env bash
printf 'root:x:0:0::/root:/bin/bash\nserver01_cicd-runner:x:1000:1000::/home/server01_cicd-runner:/bin/bash\n'
MOCK
  # cat fails mid-write only when MOCK_CAT_FAIL is set (kubeconfig placement write error).
  printf '#!/usr/bin/env bash\nif [ -n "$MOCK_CAT_FAIL" ]; then head -c 10; exit 1; fi\nexec %s "$@"\n' "$REAL_CAT" > "$B/cat"
  # NTFS (Git Bash on Windows) cannot show POSIX 0600; emulate stat only there. Linux CI uses real stat.
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) printf '#!/usr/bin/env bash
if [ "$1" = -c ] && [ "$2" = %%a ]; then echo 600; exit 0; fi
exec /usr/bin/stat "$@"
' > "$B/stat" ;;
  esac
  chmod +x "$B"/*
}

new_scenario() { # $1 name -> sets S, CPR, RR
  S="$T/$1"; mkdir -p "$S/state" "$S/bin" "$S/shm"
  write_mocks "$S/bin"
  echo "dummy-ca" > "$S/ca.crt"
  touch "$S/state/runner_active"
  CPR="$S/cp-run"; RR="$S/rn/run-1"
}
env_common() {
  export PATH="$S/bin:$ORIG_PATH" MOCK_STATE="$S/state" MOCK_BIN="$S/bin" MOCK_GRAFANA=grafana-abc
  export K="$S/bin/kubectl --kubeconfig=/etc/kubernetes/admin.conf" CA_FILE="$S/ca.crt" SHM="$S/shm"
}
cp_() { ( env_common; exec bash "$HERE/pf_cp.sh" "$@" ); }
rn_() { ( env_common; exec bash "$HERE/pf_runner.sh" "$@" ); }
kc_from() { sed -n '/^----- BEGIN KUBECONFIG/,/^----- END KUBECONFIG/p' | sed '1d;$d'; }

echo "# S1 happy path"
new_scenario s1
cp_ pre "$CPR" > /dev/null; rn_ pre "$RR" > /dev/null; rn_ stop "$RR" > /dev/null; rn_ install "$RR" > /dev/null
cp_ create "$CPR" > /dev/null; out=$(cp_ token "$CPR")
exp=$(echo "$out" | sed -n 's/^TOKEN_EXP=//p'); echo "$out" | kc_from | rn_ place "$RR" "$exp" > /dev/null
rn_ verify "$RR" grafana-abc prometheus-abc > /dev/null; cp_ recheck "$CPR" > /dev/null; rn_ pftest "$RR" grafana-abc > /dev/null
cp_ delete "$CPR" > /dev/null; rn_ cleanup "$RR" "$(stv "$CPR" TEMP_OBJECTS_REMOVED)" > /dev/null; rn_ restore "$RR" > /dev/null
for k in PRE RUNNER_STOPPED_LOCAL KUBECTL_INSTALLED KUBECONFIG_PLACED AUTHZ AUTH_IDENTITY_EXPECTED DENY_POD_LIST DENY_SECRET_GET DENY_OTHER_POD_GET DENY_OTHER_POD_PORTFORWARD ROUTE_SRC_10.250.10.20 PF_START GRAFANA_HEALTH_200 GRAFANA_UNAUTH_401 PF_PROCESS_STOPPED KUBECONFIG_REMOVED TEST_KUBECTL_REMOVED RESTORE_GATE RUNNER_RESTORED_LOCAL; do
  check "S1 $k=PASS" "[ \"\$(stv \"$RR\" $k)\" = PASS ]"
done
for k in PRE DRYRUN TEMP_RBAC_CREATED TOKEN_ACTUAL_TTL_LE_900 POD_RECHECK TEMP_OBJECTS_REMOVED; do
  check "S1 cp $k=PASS" "[ \"\$(stv \"$CPR\" $k)\" = PASS ]"
done
check "S1 old token DENIED after SA delete" "[ \"\$(stv \"$RR\" OLD_TOKEN_AUTH_AFTER_SA_DELETE)\" = DENIED ]"
check "S1 token never written on control01" "[ \"\$(grep -rl 'c2ln' \"$CPR\" | grep -c .)\" = 0 ]"
check "S1 no listener and runner active" "[ ! -f \"$S/state/listen13000\" ] && [ -f \"$S/state/runner_active\" ]"

echo "# S2 download failure -> kubectl never executed, no cluster create"
new_scenario s2
rn_ pre "$RR" > /dev/null; rn_ stop "$RR" > /dev/null
( export MOCK_DL_FAIL=1; rn_ install "$RR" > /dev/null ); rc=$?
check "S2 install rc non-zero" "[ $rc -ne 0 ]"
check "S2 kubectl not executed" "[ ! -f \"$S/state/kubectl_executed\" ]"
check "S2 no create call" "! grep -q 'create -f' \"$S/state/kubectl.calls\" 2>/dev/null"
rn_ cleanup "$RR" NOT_CREATED > /dev/null
check "S2 gate PASS with NOT_TRANSFERRED/NOT_INSTALLED" "[ \"\$(stv \"$RR\" RESTORE_GATE)\" = PASS ] && [ \"\$(stv \"$RR\" OLD_TOKEN_AUTH_AFTER_SA_DELETE)\" = NOT_TRANSFERRED ] && [ \"\$(stv \"$RR\" TEST_KUBECTL_REMOVED)\" = NOT_INSTALLED ]"

echo "# S3 checksum mismatch -> binary never executed"
new_scenario s3
rn_ pre "$RR" > /dev/null; rn_ stop "$RR" > /dev/null
( export MOCK_SHA_BAD=1; rn_ install "$RR" > /dev/null ); rc=$?
check "S3 install rc non-zero" "[ $rc -ne 0 ]"
check "S3 kubectl not executed" "[ ! -f \"$S/state/kubectl_executed\" ]"
check "S3 CHECKSUM_RC recorded non-zero" "grep -q 'CHECKSUM_RC=[1-9]' \"$RR/04-kubectl-sha.txt\""
check "S3 downloaded binary removed" "[ ! -e \"$RR/bin/kubectl\" ]"

echo "# S4 server dry-run failure -> create 0"
new_scenario s4
cp_ pre "$CPR" > /dev/null
( export MOCK_DRYRUN_FAIL=1; cp_ create "$CPR" > /dev/null ); rc=$?
check "S4 create rc non-zero" "[ $rc -ne 0 ]"
check "S4 no real create call" "[ \"\$(grep -c '^--kubeconfig=/etc/kubernetes/admin.conf create -f' \"$S/state/kubectl.calls\")\" = 0 ]"
cp_ delete "$CPR" > /dev/null
check "S4 delete NOT_CREATED" "[ \"\$(stv \"$CPR\" TEMP_OBJECTS_REMOVED)\" = NOT_CREATED ]"

echo "# S5 partial create -> no PASS, token refused, owned object removed"
new_scenario s5
cp_ pre "$CPR" > /dev/null
( export MOCK_CREATE_PARTIAL=1; cp_ create "$CPR" > /dev/null ); rc=$?
check "S5 create rc non-zero" "[ $rc -ne 0 ]"
check "S5 TEMP_RBAC_CREATED not PASS" "[ \"\$(stv \"$CPR\" TEMP_RBAC_CREATED)\" != PASS ]"
cp_ token "$CPR" > "$S/token.out"; rc=$?
check "S5 token refused and no kubeconfig output" "[ $rc -ne 0 ] && [ \"\$(grep -c 'token:' \"$S/token.out\")\" = 0 ]"
cp_ delete "$CPR" > /dev/null
check "S5 owned SA removed -> PASS" "[ \"\$(stv \"$CPR\" TEMP_OBJECTS_REMOVED)\" = PASS ] && [ ! -f \"$S/state/obj_serviceaccount\" ]"

echo "# S6 JWT parse failure / TTL over 900 -> STOP, no kubeconfig"
for v in MOCK_JWT_BAD MOCK_TTL; do
  new_scenario "s6-$v"
  cp_ pre "$CPR" > /dev/null; cp_ create "$CPR" > /dev/null
  if [ "$v" = MOCK_TTL ]; then ( export MOCK_TTL=3600; cp_ token "$CPR" > "$S/token.out" ); else ( export MOCK_JWT_BAD=1; cp_ token "$CPR" > "$S/token.out" ); fi
  rc=$?
  check "S6 $v token rc non-zero" "[ $rc -ne 0 ]"
  check "S6 $v TTL gate STOP" "stv \"$CPR\" TOKEN_ACTUAL_TTL_LE_900 | grep -q '^STOP'"
  check "S6 $v no kubeconfig printed" "[ \"\$(grep -c 'token:' \"$S/token.out\")\" = 0 ]"
done

prep_runner() { # objects created, kubeconfig placed
  cp_ pre "$CPR" > /dev/null; rn_ pre "$RR" > /dev/null; rn_ stop "$RR" > /dev/null; rn_ install "$RR" > /dev/null
  cp_ create "$CPR" > /dev/null; out=$(cp_ token "$CPR")
  exp=$(echo "$out" | sed -n 's/^TOKEN_EXP=//p'); echo "$out" | kc_from | rn_ place "$RR" "$exp" > /dev/null
  rn_ verify "$RR" grafana-abc prometheus-abc > /dev/null
}

echo "# S7 port 13000 already in use -> STOP without killing it"
new_scenario s7; prep_runner
touch "$S/state/listen13000"
rn_ pftest "$RR" grafana-abc > /dev/null; rc=$?
check "S7 pftest rc non-zero" "[ $rc -ne 0 ]"
check "S7 STOP_PORT recorded, no pf.pid, foreign listener kept" "stv \"$RR\" PF | grep -q STOP_PORT && [ ! -f \"$RR/pf.pid\" ] && [ -f \"$S/state/listen13000\" ]"

echo "# S8 port-forward start failure -> PF_START=FAIL, process gone"
new_scenario s8; prep_runner
( export MOCK_PF_FAIL=1; rn_ pftest "$RR" grafana-abc > /dev/null ); rc=$?
check "S8 pftest rc non-zero and PF_START=FAIL" "[ $rc -ne 0 ] && [ \"\$(stv \"$RR\" PF_START)\" = FAIL ]"
check "S8 PF_PROCESS_STOPPED=PASS" "[ \"\$(stv \"$RR\" PF_PROCESS_STOPPED)\" = PASS ]"

echo "# S9 HTTP timeout -> FAIL verdict, process and listener removed"
new_scenario s9; prep_runner
( export MOCK_HTTP_TIMEOUT=1; rn_ pftest "$RR" grafana-abc > /dev/null ); rc=$?
check "S9 pftest rc non-zero, health FAIL" "[ $rc -ne 0 ] && [ \"\$(stv \"$RR\" GRAFANA_HEALTH_200)\" = FAIL ]"
check "S9 PF_PROCESS_STOPPED=PASS, no listener" "[ \"\$(stv \"$RR\" PF_PROCESS_STOPPED)\" = PASS ] && [ ! -f \"$S/state/listen13000\" ]"

echo "# S10 pftest interrupted (killed) -> common cleanup stops the leftover port-forward"
new_scenario s10; prep_runner
( env_common; export MOCK_HTTP_HANG=1; exec bash "$HERE/pf_runner.sh" pftest "$RR" grafana-abc ) > /dev/null 2>&1 &
tp=$!; BG="$BG $tp"
for i in $(seq 1 50); do [ -f "$S/state/hang.pids" ] && break; sleep 0.2; done
kill -KILL "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
for p in $(cat "$S/state/hang.pids" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
pfpid=$(cat "$RR/pf.pid" 2>/dev/null)
check "S10 port-forward still running after interruption" "[ -n \"$pfpid\" ] && [ -d /proc/$pfpid ]"
cp_ delete "$CPR" > /dev/null; rn_ cleanup "$RR" "$(stv "$CPR" TEMP_OBJECTS_REMOVED)" > /dev/null
check "S10 cleanup stopped it (PF_PROCESS_STOPPED=PASS)" "[ \"\$(stv \"$RR\" PF_PROCESS_STOPPED)\" = PASS ] && [ ! -d /proc/$pfpid ] && [ ! -f \"$S/state/listen13000\" ]"
check "S10 gate PASS" "[ \"\$(stv \"$RR\" RESTORE_GATE)\" = PASS ]"

echo "# S11 object delete failure -> gate BLOCKED, restore refused, runner stays offline"
new_scenario s11; prep_runner
( export MOCK_DELETE_FAIL=1; cp_ delete "$CPR" > /dev/null )
check "S11 TEMP_OBJECTS_REMOVED=FAIL" "[ \"\$(stv \"$CPR\" TEMP_OBJECTS_REMOVED)\" = FAIL ]"
rn_ cleanup "$RR" "$(stv "$CPR" TEMP_OBJECTS_REMOVED)" > /dev/null
rn_ restore "$RR" > /dev/null; rc=$?
check "S11 gate BLOCKED, RUNNER_RESTORED=NOT_RUN" "[ \"\$(stv \"$RR\" RESTORE_GATE)\" = BLOCKED ] && grep -q '^RUNNER_RESTORED=NOT_RUN' \"$RR/status.txt\""
check "S11 restore refused, runner offline" "[ $rc -ne 0 ] && [ ! -f \"$S/state/runner_active\" ]"

echo "# S12 pf.pid points to an unrelated live process -> not killed, gate BLOCKED"
new_scenario s12; prep_runner
( while :; do sleep 0.2; done ) & other=$!; BG="$BG $other"
echo "$other" > "$RR/pf.pid"; printf 'something else\n1\n' > "$RR/pf.ident"
cp_ delete "$CPR" > /dev/null; rn_ cleanup "$RR" "$(stv "$CPR" TEMP_OBJECTS_REMOVED)" > /dev/null
check "S12 FAIL_IDENTITY_MISMATCH and process untouched" "[ \"\$(stv \"$RR\" PF_PROCESS_STOPPED)\" = FAIL_IDENTITY_MISMATCH ] && [ -d /proc/$other ]"
check "S12 gate BLOCKED" "[ \"\$(stv \"$RR\" RESTORE_GATE)\" = BLOCKED ]"

echo "# S13 old token still authenticates -> NOT_DENIED, gate BLOCKED"
new_scenario s13; prep_runner
cp_ delete "$CPR" > /dev/null
( export MOCK_TOKEN_STILL_VALID=1; rn_ cleanup "$RR" "$(stv "$CPR" TEMP_OBJECTS_REMOVED)" > /dev/null )
check "S13 NOT_DENIED and gate BLOCKED" "[ \"\$(stv \"$RR\" OLD_TOKEN_AUTH_AFTER_SA_DELETE)\" = NOT_DENIED ] && [ \"\$(stv \"$RR\" RESTORE_GATE)\" = BLOCKED ]"

echo "# S14 over-broad RBAC (list pods allowed) -> AUTHZ FAIL"
new_scenario s14; prep_runner
( export MOCK_CANI_WIDE=1; rn_ verify "$RR" grafana-abc prometheus-abc > /dev/null ); rc=$?
check "S14 verify rc non-zero, DENY_POD_LIST=FAIL" "[ $rc -ne 0 ] && [ \"\$(stv \"$RR\" DENY_POD_LIST)\" = FAIL ]"

echo "# S15 create race: same name replaced after our create -> not adopted, no token, foreign object kept, BLOCKED"
new_scenario s15
cp_ pre "$CPR" > /dev/null; rn_ pre "$RR" > /dev/null; rn_ stop "$RR" > /dev/null
( export MOCK_REPLACE_AFTER=serviceaccount; cp_ create "$CPR" > /dev/null )
check "S15 ownership is the create-response UID" "grep -qx 'UID_serviceaccount=uid-sa' \"$CPR/created.env\" && ! grep -q uid-replacement \"$CPR/created.env\""
cp_ token "$CPR" > "$S/token.out"; rc=$?
check "S15 token refused (ownership mismatch), no kubeconfig" "[ $rc -ne 0 ] && [ \"\$(stv \"$CPR\" TOKEN)\" = STOP_OWNERSHIP_MISMATCH ] && [ \"\$(grep -c 'token:' \"$S/token.out\")\" = 0 ] && [ -z \"\$(stv \"$CPR\" TOKEN_ISSUED)\" ]"
cp_ delete "$CPR" > /dev/null
check "S15 foreign SA not deleted, delete FAIL" "[ \"\$(cat \"$S/state/obj_serviceaccount\")\" = uid-replacement ] && [ \"\$(stv \"$CPR\" TEMP_OBJECTS_REMOVED)\" = FAIL ]"
check "S15 owned role/rolebinding removed" "[ ! -f \"$S/state/obj_role\" ] && [ ! -f \"$S/state/obj_rolebinding\" ]"
rn_ cleanup "$RR" "$(stv "$CPR" TEMP_OBJECTS_REMOVED)" > /dev/null; rn_ restore "$RR" > /dev/null; rc=$?
check "S15 gate BLOCKED, runner offline" "[ \"\$(stv \"$RR\" RESTORE_GATE)\" = BLOCKED ] && [ $rc -ne 0 ] && [ ! -f \"$S/state/runner_active\" ]"

echo "# S16 create response lost -> ownership kept as recorded, rerun refused, unowned object not deleted"
new_scenario s16
cp_ pre "$CPR" > /dev/null
( export MOCK_CREATE_LOST=role; cp_ create "$CPR" > /dev/null ); rc=$?
check "S16 create rc non-zero, FAIL_AT_role, SA ownership kept" "[ $rc -ne 0 ] && [ \"\$(stv \"$CPR\" TEMP_RBAC_CREATED)\" = FAIL_AT_role ] && grep -qx 'UID_serviceaccount=uid-sa' \"$CPR/created.env\" && ! grep -q UID_role \"$CPR/created.env\""
cp_ create "$CPR" > /dev/null; rc=$?
check "S16 second create refused, created.env preserved" "[ $rc -ne 0 ] && [ \"\$(stv \"$CPR\" CREATE)\" = STOP_ALREADY_RAN ] && grep -qx 'UID_serviceaccount=uid-sa' \"$CPR/created.env\""
cp_ token "$CPR" > "$S/token.out"; rc=$?
check "S16 token refused" "[ $rc -ne 0 ] && [ \"\$(grep -c 'token:' \"$S/token.out\")\" = 0 ]"
cp_ delete "$CPR" > /dev/null
check "S16 owned SA removed, unowned role kept, delete FAIL" "[ ! -f \"$S/state/obj_serviceaccount\" ] && [ -f \"$S/state/obj_role\" ] && [ \"\$(stv \"$CPR\" TEMP_OBJECTS_REMOVED)\" = FAIL ]"

echo "# S17 ss failure at pre -> STOP (not counted as 0)"
new_scenario s17
( export MOCK_SS_FAIL=1; rn_ pre "$RR" > /dev/null ); rc=$?
check "S17 PRE=STOP_LISTENER_UNKNOWN" "[ $rc -ne 0 ] && [ \"\$(stv \"$RR\" PRE)\" = STOP_LISTENER_UNKNOWN ] && grep -q 'rc=1' \"$RR/ss.log\""

echo "# S18 ss failure at cleanup -> FAIL_LISTENER_UNKNOWN, gate BLOCKED"
new_scenario s18; prep_runner
rn_ pftest "$RR" grafana-abc > /dev/null
cp_ delete "$CPR" > /dev/null
( export MOCK_SS_FAIL=1; rn_ cleanup "$RR" "$(stv "$CPR" TEMP_OBJECTS_REMOVED)" > /dev/null )
check "S18 FAIL_LISTENER_UNKNOWN and BLOCKED" "[ \"\$(stv \"$RR\" PF_PROCESS_STOPPED)\" = FAIL_LISTENER_UNKNOWN ] && [ \"\$(stv \"$RR\" RESTORE_GATE)\" = BLOCKED ]"
rn_ restore "$RR" > /dev/null; rc=$?
check "S18 restore refused" "[ $rc -ne 0 ] && [ ! -f \"$S/state/runner_active\" ]"

echo "# S19 no pf.pid but port 13000 held by another process -> not killed, BLOCKED, restore refused"
new_scenario s19
rn_ pre "$RR" > /dev/null; rn_ stop "$RR" > /dev/null
touch "$S/state/listen13000"
rn_ cleanup "$RR" NOT_CREATED > /dev/null
check "S19 FAIL_FOREIGN_LISTENER, listener kept" "[ \"\$(stv \"$RR\" PF_PROCESS_STOPPED)\" = FAIL_FOREIGN_LISTENER ] && [ -f \"$S/state/listen13000\" ]"
rn_ restore "$RR" > /dev/null; rc=$?
check "S19 gate BLOCKED, restore refused, runner offline" "[ \"\$(stv \"$RR\" RESTORE_GATE)\" = BLOCKED ] && [ $rc -ne 0 ] && [ ! -f \"$S/state/runner_active\" ]"

echo "# S20 runner stop failed -> install/place refused, no kubeconfig written"
new_scenario s20
rn_ pre "$RR" > /dev/null
( export MOCK_STOP_FAIL=1; rn_ stop "$RR" > /dev/null )
rn_ install "$RR" > /dev/null; rc1=$?
echo 'token: x' | rn_ place "$RR" 9999999999 > /dev/null; rc2=$?
check "S20 install and place refused" "[ $rc1 -ne 0 ] && [ $rc2 -ne 0 ] && [ \"\$(stv \"$RR\" PLACE)\" = STOP_RUNNER_NOT_STOPPED ] && [ \"\$(stv \"$RR\" INSTALL)\" = STOP_RUNNER_NOT_STOPPED ]"
check "S20 no kubeconfig file, no PLACE_STARTED" "[ \"\$(ls \"$S/shm\" | grep -c .)\" = 0 ] && [ -z \"\$(stv \"$RR\" PLACE_STARTED)\" ]"

echo "# S21 cleanup closes the run: later place refused; stale gate cannot restart over residue"
new_scenario s21
rn_ pre "$RR" > /dev/null; rn_ stop "$RR" > /dev/null
rn_ cleanup "$RR" NOT_CREATED > /dev/null
echo 'token: x' | rn_ place "$RR" 9999999999 > /dev/null; rc=$?
check "S21 place after cleanup refused, no file" "[ $rc -ne 0 ] && [ \"\$(stv \"$RR\" PLACE)\" = STOP_CLEANUP_ALREADY_STARTED ] && [ \"\$(ls \"$S/shm\" | grep -c .)\" = 0 ]"
echo 'token: x' > "$S/shm/p1-mon-pf-verify-run-1.kubeconfig"
rn_ restore "$RR" > /dev/null; rc=$?
check "S21 residual kubeconfig -> restore refused" "[ $rc -ne 0 ] && stv \"$RR\" RUNNER_RESTORED | grep -q '^REFUSED_RESIDUAL_kubeconfig' && [ ! -f \"$S/state/runner_active\" ]"
rm -f "$S/shm/p1-mon-pf-verify-run-1.kubeconfig"
rn_ restore "$RR" > /dev/null; rc=$?
check "S21 clean -> restore PASS" "[ $rc -eq 0 ] && [ \"\$(stv \"$RR\" RUNNER_RESTORED_LOCAL)\" = PASS ]"

echo "# S22 place interrupted (state injection) -> PLACE_INTERRUPTED, never NOT_TRANSFERRED, BLOCKED"
for v in file-partial file-complete no-file; do
  new_scenario "s22-$v"
  rn_ pre "$RR" > /dev/null; rn_ stop "$RR" > /dev/null
  printf 'TOKEN_EXP=9999999999\nPLACE_STARTED=injected\n' >> "$RR/status.txt"
  case "$v" in
    file-partial) printf 'apiVersion: v1\nkind: Con' > "$S/shm/p1-mon-pf-verify-run-1.kubeconfig" ;;
    file-complete) printf 'users:\n- user: {token: dummy}\n' > "$S/shm/p1-mon-pf-verify-run-1.kubeconfig" ;;
  esac
  rn_ cleanup "$RR" NOT_CREATED > /dev/null
  check "S22 $v PLACE_INTERRUPTED, file removed, BLOCKED" "[ \"\$(stv \"$RR\" OLD_TOKEN_AUTH_AFTER_SA_DELETE)\" = PLACE_INTERRUPTED ] && [ \"\$(stv \"$RR\" KUBECONFIG_REMOVED)\" = PASS ] && [ \"\$(ls \"$S/shm\" | grep -c .)\" = 0 ] && [ \"\$(stv \"$RR\" RESTORE_GATE)\" = BLOCKED ]"
done

echo "# S23 kubeconfig write RC failure -> partial file removed, explicit failure recorded"
new_scenario s23
rn_ pre "$RR" > /dev/null; rn_ stop "$RR" > /dev/null
( export MOCK_CAT_FAIL=1; printf 'apiVersion: v1\nusers:\n- user: {token: dummy}\n' | rn_ place "$RR" 9999999999 > /dev/null ); rc=$?
check "S23 place rc non-zero, FAIL_WRITE_REMOVED, file gone" "[ $rc -ne 0 ] && [ \"\$(stv \"$RR\" KUBECONFIG_PLACED)\" = FAIL_WRITE_REMOVED ] && [ \"\$(ls \"$S/shm\" | grep -c .)\" = 0 ]"
rn_ verify "$RR" grafana-abc prometheus-abc > /dev/null; rc=$?
check "S23 verify refused after failed place" "[ $rc -ne 0 ] && [ \"\$(stv \"$RR\" AUTHZ)\" = STOP_NOT_PLACED ]"
rn_ cleanup "$RR" NOT_CREATED > /dev/null
check "S23 PLACE_FAILED_FILE_REMOVED (not NOT_TRANSFERRED)" "[ \"\$(stv \"$RR\" OLD_TOKEN_AUTH_AFTER_SA_DELETE)\" = PLACE_FAILED_FILE_REMOVED ] && [ \"\$(stv \"$RR\" KUBECONFIG_REMOVED)\" = PASS ]"

echo "# S24 relative RUN path is normalized to an absolute path"
new_scenario s24
( env_common; cd "$S" && bash "$HERE/pf_cp.sh" pre cp-rel > /dev/null && bash "$HERE/pf_cp.sh" create cp-rel > /dev/null )
check "S24 status written inside the run dir" "[ \"\$(stv \"$S/cp-rel\" TEMP_RBAC_CREATED)\" = PASS ] && [ ! -e \"$S/cp-rel/cp-rel\" ]"

echo
echo "RESULT pass=$pass fail=$fail"
[ "$fail" = 0 ]
