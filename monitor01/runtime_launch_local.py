#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, os, pwd, re, shutil, socket, subprocess, sys
from pathlib import Path

HOST="monitor01"
LOGIN="server01_monitor"
RECEIVER_NAME="fds-monitor01-receiver"
BLACKBOX_NAME="fds-monitor01-blackbox"
RECEIVER_HOST_CONFIG=Path("/etc/fds/monitor01/receiver/prometheus.yml")
RECEIVER_HOST_DATA=Path("/var/lib/fds/monitor01/receiver")
BLACKBOX_HOST_CONFIG=Path("/etc/fds/monitor01/blackbox/blackbox.yml")
IMAGE_RE=re.compile(r"^10\\.1\\.93\\.54/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$")

class Stop(RuntimeError): pass

def run(argv, check=True):
    p=subprocess.run(argv,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=False)
    if check and p.returncode!=0:
        raise Stop(f"command failed rc={p.returncode}: {argv!r}\\n{p.stderr.strip()}")
    return p

def require_identity():
    host=socket.gethostname().split(".",1)[0]
    user=pwd.getpwuid(os.getuid()).pw_name
    if host!=HOST or user!=LOGIN or os.getuid()==0:
        raise Stop(f"run as {LOGIN} on {HOST}; root/direct execution is not allowed")
    podman,ss=shutil.which("podman"),shutil.which("ss")
    if not podman or not ss: raise Stop("podman and ss are required")
    return str(Path(podman).resolve()),str(Path(ss).resolve())

def require_digest(v,label):
    if not IMAGE_RE.fullmatch(v): raise Stop(f"{label} must be an approved Harbor digest reference")
    return v

def exists(podman,name):
    return run([podman,"container","exists",name],check=False).returncode==0

def remove(podman,name):
    if exists(podman,name): run([podman,"rm","-f",name],check=False)

def verify(ss):
    lines=run([ss,"-ltnH"]).stdout.splitlines()
    out={}
    for port in (19090,9115):
        matches=[x for x in lines if f":{port}" in x]
        if not matches: raise Stop(f"listener {port} missing")
        bad=[x for x in matches if f"127.0.0.1:{port}" not in x]
        if bad: raise Stop(f"listener {port} is not localhost-only: {bad}")
        out[str(port)]=matches
    return out

def start(args):
    podman,ss=require_identity()
    ri=require_digest(args.receiver_image,"receiver image")
    bi=require_digest(args.blackbox_image,"blackbox image")
    for p in (RECEIVER_HOST_CONFIG,BLACKBOX_HOST_CONFIG):
        if not p.is_file() or p.is_symlink(): raise Stop(f"required config missing/unsafe: {p}")
    if not RECEIVER_HOST_DATA.is_dir() or RECEIVER_HOST_DATA.is_symlink():
        raise Stop(f"receiver data directory missing/unsafe: {RECEIVER_HOST_DATA}")
    for name in (RECEIVER_NAME,BLACKBOX_NAME):
        if exists(podman,name): raise Stop(f"container already exists: {name}")
    rc=[podman,"run","-d","--name",RECEIVER_NAME,"--network","host","--security-opt","no-new-privileges","--cap-drop","all",
        "-v",f"{RECEIVER_HOST_CONFIG}:/etc/prometheus/prometheus.yml:ro,Z",
        "-v",f"{RECEIVER_HOST_DATA}:/prometheus:Z",ri,
        "--config.file=/etc/prometheus/prometheus.yml","--storage.tsdb.path=/prometheus",
        "--web.listen-address=127.0.0.1:19090","--web.enable-remote-write-receiver"]
    bc=[podman,"run","-d","--name",BLACKBOX_NAME,"--network","host","--security-opt","no-new-privileges","--cap-drop","all",
        "-v",f"{BLACKBOX_HOST_CONFIG}:/etc/blackbox/blackbox.yml:ro,Z",bi,
        "--config.file=/etc/blackbox/blackbox.yml","--web.listen-address=127.0.0.1:9115"]
    started=[]
    try:
        run(rc); started.append(RECEIVER_NAME)
        run(bc); started.append(BLACKBOX_NAME)
        listeners=verify(ss)
    except BaseException:
        for n in reversed(started): remove(podman,n)
        raise
    print(json.dumps({"status":"LOCAL_SERVICES_STARTED","runtime":"RUNNING_NOT_ACCEPTED","containers":started,
                      "listeners":listeners,"receiver_image":ri,"blackbox_image":bi},ensure_ascii=False,indent=2))

def stop(_args):
    podman,_=require_identity()
    for n in (BLACKBOX_NAME,RECEIVER_NAME): remove(podman,n)
    print(json.dumps({"status":"LOCAL_SERVICES_STOPPED","containers":[BLACKBOX_NAME,RECEIVER_NAME]},indent=2))

def main():
    p=argparse.ArgumentParser()
    sub=p.add_subparsers(dest="command",required=True)
    s=sub.add_parser("start"); s.add_argument("--receiver-image",required=True); s.add_argument("--blackbox-image",required=True); s.set_defaults(func=start)
    t=sub.add_parser("stop"); t.set_defaults(func=stop)
    a=p.parse_args(); a.func(a); return 0

if __name__=="__main__":
    try: raise SystemExit(main())
    except (Stop,KeyboardInterrupt) as exc:
        print(f"STOP: {type(exc).__name__}: {exc}",file=sys.stderr); raise SystemExit(2)
