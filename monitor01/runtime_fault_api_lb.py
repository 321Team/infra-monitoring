#!/usr/bin/env python3
from __future__ import annotations
import argparse, datetime as dt, json, os, re, shutil, socket, subprocess, sys, time
from pathlib import Path

HOST="monitor01"
SUDO_USER="server01_monitor"
TARGET="10.1.93.109"
PORT="6443"
TAG_RE=re.compile(r"^[A-Za-z0-9_.-]{1,48}$")

class Stop(RuntimeError): pass

def stamp(): return dt.datetime.now(dt.timezone.utc).isoformat()
def emit(event,**values): print(json.dumps({"time_utc":stamp(),"event":event,**values},ensure_ascii=False),flush=True)

def run(argv,check=True):
    p=subprocess.run(argv,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=False)
    emit("command",argv=argv,rc=p.returncode,stdout=p.stdout,stderr=p.stderr)
    if check and p.returncode!=0: raise Stop(f"command failed rc={p.returncode}: {argv!r}")
    return p

def require_identity():
    if socket.gethostname().split(".",1)[0]!=HOST: raise Stop(f"run only on {HOST}")
    if os.geteuid()!=0 or os.environ.get("SUDO_USER")!=SUDO_USER:
        raise Stop(f"run with sudo -n from {SUDO_USER}; direct root login is not accepted")
    out={}
    for n in ("firewall-cmd","systemd-run","systemctl","ss"):
        v=shutil.which(n)
        if not v: raise Stop(f"missing tool: {n}")
        out[n]=str(Path(v).resolve())
    return out

def exact_rule(tag):
    return ["ipv4","filter","OUTPUT","0","-d",f"{TARGET}/32","-p","tcp","--dport",PORT,"-m","comment","--comment",tag,"-j","REJECT"]

def target_rule_exists(value):
    return any(" filter OUTPUT " in f" {line} " and TARGET in line and PORT in line for line in value.splitlines())

def tagged_rule_exists(value,tag): return any(tag in line for line in value.splitlines())

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--ack-hostwide",action="store_true")
    p.add_argument("--duration",type=int,default=180)
    a=p.parse_args()
    if not a.ack_hostwide: raise Stop("--ack-hostwide is required")
    if not 30<=a.duration<=180: raise Stop("duration must be 30..180 seconds")
    tools=require_identity()
    fw,systemd_run,systemctl,ss=tools["firewall-cmd"],tools["systemd-run"],tools["systemctl"],tools["ss"]
    run([fw,"--state"])
    before=run([fw,"--direct","--get-all-rules"]).stdout
    if target_rule_exists(before): raise Stop("pre-existing OUTPUT rule for 10.1.93.109:6443 detected; do not overlap it")
    conns=[x for x in run([ss,"-tnpH"],check=False).stdout.splitlines() if f"{TARGET}:{PORT}" in x]
    emit("impact_boundary",scope=f"ALL {HOST} OUTPUT TCP to {TARGET}:{PORT}",current_connections=conns,acknowledged=True)
    tag=f"FDS_MON19_{int(time.time())}_{os.getpid()}"
    if not TAG_RE.fullmatch(tag): raise Stop("generated rule tag is invalid")
    unit=tag.lower(); rule=exact_rule(tag)
    add=[fw,"--direct","--add-rule",*rule]
    remove=[fw,"--direct","--remove-rule",*rule]
    timer=[systemd_run,"--quiet","--collect",f"--unit={unit}",f"--on-active={a.duration}s","--timer-property=AccuracySec=1s",
           fw,"--direct","--remove-rule",*rule]
    timer_armed=False; rule_added=False
    try:
        run(timer); timer_armed=True; emit("auto_recovery_armed",unit=unit,duration_seconds=a.duration)
        run(add); rule_added=True
        after=run([fw,"--direct","--get-all-rules"]).stdout
        if not tagged_rule_exists(after,tag): raise Stop("fault rule not visible after add")
        emit("fault_active",tag=tag,target=f"{TARGET}:{PORT}")
        deadline=time.monotonic()+a.duration
        while True:
            remaining=deadline-time.monotonic()
            if remaining<=0: break
            time.sleep(min(30,remaining)); emit("fault_heartbeat",remaining_seconds=max(0,round(deadline-time.monotonic(),1)))
    finally:
        if rule_added: run(remove,check=False)
        if timer_armed:
            run([systemctl,"stop",f"{unit}.timer",f"{unit}.service"],check=False)
            run([systemctl,"reset-failed",f"{unit}.service"],check=False)
    final=run([fw,"--direct","--get-all-rules"]).stdout
    if tagged_rule_exists(final,tag): raise Stop("fault rule remains after cleanup")
    emit("fault_recovered",tag=tag,target=f"{TARGET}:{PORT}")
    return 0

if __name__=="__main__":
    try: raise SystemExit(main())
    except (Stop,KeyboardInterrupt) as exc:
        print(f"STOP: {type(exc).__name__}: {exc}",file=sys.stderr); raise SystemExit(2)
