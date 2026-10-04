#!/usr/bin/env bash
# P1-MON-01 #17 approved-terminal port-forward retest - control01 side.
# Subcommands: pre | create | token | recheck | delete   (each takes RUN_DIR)
# No `set -e`: every step checks its own RC so the common cleanup can always run.
# Status lines are appended to RUN_DIR/status.txt as KEY=VALUE. The token is never written to disk.
NS=monitoring-api
NAME=p1-mon-pf-verify
K=${K:-"sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf"}
CA_FILE=${CA_FILE:-/etc/kubernetes/pki/ca.crt}
API=${API:-https://10.1.93.109:6443}
KINDS="serviceaccount role rolebinding"

cmd=$1
RUN=$2
if [ -z "$cmd" ] || [ -z "$RUN" ]; then
  echo "usage: $0 {pre|create|token|recheck|delete} RUN_DIR" >&2
  exit 2
fi

now() { TZ=Asia/Seoul date '+%F %T %Z'; }
rec() { echo "$1" | tee -a "$RUN/status.txt"; }

raw_path() {
  case "$1" in
    serviceaccount) echo "/api/v1/namespaces/$NS/serviceaccounts/$NAME" ;;
    role) echo "/apis/rbac.authorization.k8s.io/v1/namespaces/$NS/roles/$NAME" ;;
    rolebinding) echo "/apis/rbac.authorization.k8s.io/v1/namespaces/$NS/rolebindings/$NAME" ;;
  esac
}

# Prints "absent", "present <uid>" or "error"; detail goes to the given file.
obj_state() {
  local out rc
  out=$($K -n "$NS" get "$1" "$NAME" -o jsonpath='{.metadata.uid}' 2>"$2")
  rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then echo "present $out"; return; fi
  if grep -q NotFound "$2"; then echo "absent"; else echo "error"; fi
}

pod_state() {
  $K -n "$NS" get pod "$1" -o jsonpath='{.metadata.name} {.metadata.uid} ready={.status.containerStatuses[0].ready}'
}

do_pre() {
  mkdir "$RUN" || { echo "STOP: cannot create $RUN (already exists?)" >&2; return 1; }
  cd "$RUN" || return 1
  now > 00-time.txt
  $K config current-context > 01-context.txt 2>&1 || { rec "PRE=STOP_CONTEXT"; return 1; }
  $K -n "$NS" get pods -o wide > 02-pods.txt 2>&1 || { rec "PRE=STOP_PODS"; return 1; }
  local g o
  g=$($K -n "$NS" get pod -l app=grafana -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || { rec "PRE=STOP_GRAFANA_GET"; return 1; }
  o=$($K -n "$NS" get pod -l app=prometheus -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || { rec "PRE=STOP_OTHER_GET"; return 1; }
  [ "$(printf '%s\n' "$g" | grep -c .)" = 1 ] || { rec "PRE=STOP_GRAFANA_POD_COUNT"; return 1; }
  [ -n "$o" ] || { rec "PRE=STOP_NO_OTHER_POD"; return 1; }
  pod_state "$g" > 03-grafana-pre.txt || { rec "PRE=STOP_GRAFANA_STATE"; return 1; }
  grep -q 'ready=true$' 03-grafana-pre.txt || { rec "PRE=STOP_GRAFANA_NOT_READY"; return 1; }
  printf 'GRAFANA_POD=%s\nOTHER_POD=%s\n' "$g" "$(printf '%s\n' "$o" | head -1)" > pinned.env
  local k s bad=0
  for k in $KINDS; do
    s=$(obj_state "$k" "04-absent-$k.err")
    echo "$k $s" >> 04-absent.txt
    [ "$s" = absent ] || bad=1
  done
  [ "$bad" = 0 ] || { rec "PRE=STOP_OBJECT_EXISTS_OR_ERROR"; return 1; }
  $K -n "$NS" get svc grafana -o jsonpath='{.spec.type}' > 05-grafana-svc-type.txt 2>&1 || { rec "PRE=STOP_SVC"; return 1; }
  $K get ingress -A -o json > 06-ingress.json 2>06-ingress.err || { rec "PRE=STOP_INGRESS_GET"; return 1; }
  python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["items"]))' 06-ingress.json > 06-ingress-count.txt || { rec "PRE=STOP_INGRESS_PARSE"; return 1; }
  cat pinned.env
  rec "PRE=PASS"
}

do_create() {
  cd "$RUN" || return 1
  . ./pinned.env || return 1
  pod_state "$GRAFANA_POD" > 07-grafana-before-create.txt || { rec "CREATE=STOP_POD_GET"; return 1; }
  cmp -s 03-grafana-pre.txt 07-grafana-before-create.txt || { rec "CREATE=STOP_POD_CHANGED"; return 1; }
  cat > pf-verify.yaml <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: $NAME, namespace: $NS}
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: $NAME, namespace: $NS}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    resourceNames: ["$GRAFANA_POD"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["pods/portforward"]
    resourceNames: ["$GRAFANA_POD"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: $NAME, namespace: $NS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: $NAME}
subjects: [{kind: ServiceAccount, name: $NAME, namespace: $NS}]
YAML
  sha256sum pf-verify.yaml > 08-manifest.sha256
  local rc
  $K create --dry-run=server -f pf-verify.yaml > 09-dryrun.txt 2>&1
  rc=$?; echo "rc=$rc" >> 09-dryrun.txt
  [ "$rc" -eq 0 ] || { rec "DRYRUN=FAIL"; return 1; }
  rec "DRYRUN=PASS"
  $K create -f pf-verify.yaml > 10-create.txt 2>&1
  rc=$?; echo "rc=$rc" >> 10-create.txt
  # Own only objects this run reported as created; never adopt a same-name object.
  : > created.env
  local k s n
  for k in $KINDS; do
    if grep -E -q "^$k(\.rbac\.authorization\.k8s\.io)?/$NAME created" 10-create.txt; then
      s=$(obj_state "$k" "11-created-$k.err")
      case "$s" in present\ *) echo "UID_$k=${s#present }" >> created.env ;; esac
    fi
  done
  n=$(grep -c . created.env)
  if [ "$rc" -eq 0 ] && [ "$n" = 3 ]; then rec "TEMP_RBAC_CREATED=PASS"; return 0; fi
  rec "TEMP_RBAC_CREATED=FAIL_RC_${rc}_OWNED_$n"
  return 1
}

do_token() {
  cd "$RUN" || return 1
  [ -f created.env ] && [ "$(grep -c . created.env)" = 3 ] || { rec "TOKEN=STOP_OBJECTS_NOT_CREATED"; return 1; }
  $K auth whoami > 12-tokenrequest-caller.txt 2>&1 || { rec "TOKEN=STOP_WHOAMI"; return 1; }
  grep -q 'kubernetes-admin' 12-tokenrequest-caller.txt || { rec "TOKEN=STOP_UNEXPECTED_CALLER"; return 1; }
  local T rc CA
  T=$($K -n "$NS" create token "$NAME" --duration=10m 2>13-token.err)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$T" ]; then echo "rc=$rc" >> 13-token.err; rec "TOKEN_ISSUED=FAIL"; return 1; fi
  rec "TOKEN_ISSUED=YES"
  printf '%s' "$T" | python3 -c '
import sys,json,base64,time
try:
    p=sys.stdin.read().split(".")[1]; p+="="*(-len(p)%4); d=json.loads(base64.urlsafe_b64decode(p))
    sub,aud,iat,exp=d["sub"],d["aud"],int(d["iat"]),int(d["exp"])
except Exception as e:
    print("PARSE_ERROR",type(e).__name__); sys.exit(3)
t=exp-iat
f=lambda x:time.strftime("%Y-%m-%d %H:%M:%S",time.localtime(x))
print("sub=",sub); print("aud=",aud); print("iat=",iat,f(iat)); print("exp=",exp,f(exp)); print("ttl_s=",t)
sys.exit(0 if (aud and 0 < t <= 900) else 4)' > 14-token-claims.txt 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then unset T; rec "TOKEN_ACTUAL_TTL_LE_900=STOP_RC_$rc"; return 1; fi
  rec "TOKEN_ACTUAL_TTL_LE_900=PASS"
  CA=$(sudo base64 -w0 "$CA_FILE") || { unset T; rec "KUBECONFIG_RENDER=FAIL"; return 1; }
  [ -n "$CA" ] || { unset T; rec "KUBECONFIG_RENDER=FAIL"; return 1; }
  echo "TOKEN_EXP=$(sed -n 's/^exp= \([0-9]*\).*/\1/p' 14-token-claims.txt)"
  echo "----- BEGIN KUBECONFIG (copy to runner, do not save here) -----"
  cat <<KCFG
apiVersion: v1
kind: Config
clusters:
- name: fds
  cluster: {server: "$API", certificate-authority-data: $CA}
users:
- name: $NAME
  user: {token: $T}
contexts:
- name: pf
  context: {cluster: fds, user: $NAME, namespace: $NS}
current-context: pf
KCFG
  echo "----- END KUBECONFIG -----"
  unset T CA
  rec "KUBECONFIG_RENDERED=YES"
}

do_recheck() {
  cd "$RUN" || return 1
  . ./pinned.env || return 1
  pod_state "$GRAFANA_POD" > 15-grafana-before-pf.txt || { rec "POD_RECHECK=STOP_GET"; return 1; }
  cmp -s 03-grafana-pre.txt 15-grafana-before-pf.txt || { rec "POD_RECHECK=STOP_CHANGED"; return 1; }
  rec "POD_RECHECK=PASS"
}

do_delete() {
  cd "$RUN" || return 1
  [ -f created.env ] && . ./created.env
  local k s want path ok=1 owned=0
  for k in rolebinding role serviceaccount; do
    eval "want=\${UID_$k:-}"
    [ -n "$want" ] && owned=$((owned + 1))
    s=$(obj_state "$k" "16-pre-delete-$k.err")
    echo "$k $s owned=${want:-none}" >> 16-pre-delete.txt
    case "$s" in
      absent) continue ;;
      error) ok=0; continue ;;
    esac
    if [ -z "$want" ] || [ "${s#present }" = "$want" ]; then :; else ok=0; echo "$k SKIP_FOREIGN" >> 16-pre-delete.txt; continue; fi
    [ -n "$want" ] || { ok=0; echo "$k SKIP_NOT_OWNED" >> 16-pre-delete.txt; continue; }
    path=$(raw_path "$k")
    printf '{"apiVersion":"v1","kind":"DeleteOptions","preconditions":{"uid":"%s"}}' "$want" \
      | $K delete --raw="$path" -f - > "17-delete-$k.txt" 2>&1 || ok=0
  done
  local remain=0
  for k in $KINDS; do
    s=$(obj_state "$k" "18-post-delete-$k.err")
    echo "$k $s" >> 18-post-delete.txt
    [ "$s" = absent ] || remain=1
  done
  if [ "$ok" = 1 ] && [ "$remain" = 0 ]; then
    if [ "$owned" = 0 ]; then rec "TEMP_OBJECTS_REMOVED=NOT_CREATED"; else rec "TEMP_OBJECTS_REMOVED=PASS"; fi
    return 0
  fi
  rec "TEMP_OBJECTS_REMOVED=FAIL"
  return 1
}

case "$cmd" in
  pre) do_pre ;;
  create) do_create ;;
  token) do_token ;;
  recheck) do_recheck ;;
  delete) do_delete ;;
  *) echo "unknown subcommand: $cmd" >&2; exit 2 ;;
esac
