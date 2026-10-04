#!/usr/bin/env bash
# P1-MON-01 #17 port-forward retest - PC side GitHub API record of the infra-cicd self-hosted runner.
# Usage: pf_gh.sh {pre|after_stop|post_restore} OUT_DIR
# Saves raw JSON, the exact endpoint, KST time and gh RC for each query; the verdict is read
# from the saved JSON (no second query), so the recorded state and the verdict are the same sample.
REPO=${REPO:-321Team/infra-cicd}
RUNNER=${RUNNER:-cicd-runner01}
stage=$1
OUT=$2
if [ -z "$stage" ] || [ -z "$OUT" ]; then echo "usage: $0 {pre|after_stop|post_restore} OUT_DIR" >&2; exit 2; fi
mkdir -p "$OUT" || exit 1

q() { # name endpoint
  local f="$OUT/$stage-$1.json" rc
  gh api "$2" > "$f" 2> "$f.err"
  rc=$?
  printf '%s %s rc=%s endpoint=GET /%s\n' "$(TZ=Asia/Seoul date '+%F %T %Z')" "$1" "$rc" "$2" >> "$OUT/$stage-meta.txt"
  return "$rc"
}

q runners "repos/$REPO/actions/runners" || { echo "$stage RESULT=STOP_API_RUNNERS" | tee -a "$OUT/verdict.txt"; exit 1; }
if [ "$stage" = pre ]; then
  q queued "repos/$REPO/actions/runs?status=queued&per_page=1" || { echo "$stage RESULT=STOP_API_QUEUED" | tee -a "$OUT/verdict.txt"; exit 1; }
  q in_progress "repos/$REPO/actions/runs?status=in_progress&per_page=1" || { echo "$stage RESULT=STOP_API_IN_PROGRESS" | tee -a "$OUT/verdict.txt"; exit 1; }
fi

python3 - "$OUT" "$stage" "$RUNNER" <<'PY'
import json, os, sys
out, stage, name = sys.argv[1:4]
load = lambda n: json.load(open(os.path.join(out, f"{stage}-{n}.json"), encoding="utf-8"))
rs = [r for r in load("runners").get("runners", []) if r.get("name") == name]
if len(rs) == 1:
    r = rs[0]
    line = f"{stage} runner_name={r['name']} runner_id={r['id']} runner_status={r['status']} runner_busy={str(r['busy']).lower()}"
    status, busy = r["status"], r["busy"]
else:
    line, status, busy = f"{stage} runner_name={name} RUNNER_NOT_FOUND_OR_DUPLICATE count={len(rs)}", None, None
if stage == "pre":
    qd, ip = load("queued").get("total_count"), load("in_progress").get("total_count")
    line += f" queued={qd} in_progress={ip}"
    ok = status == "online" and busy is False and qd == 0 and ip == 0
elif stage == "after_stop":
    ok = status == "offline"
else:
    ok = status == "online"
line += " RESULT=" + ("PASS" if ok else "FAIL")
print(line)
open(os.path.join(out, "verdict.txt"), "a", encoding="utf-8").write(line + "\n")
sys.exit(0 if ok else 1)
PY
