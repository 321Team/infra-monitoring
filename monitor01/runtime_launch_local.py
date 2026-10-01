#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, os, pwd, re, shutil, socket, subprocess, sys, time
from pathlib import Path

HOST="monitor01"
LOGIN="server01_monitor"
RECEIVER_NAME="fds-monitor01-receiver"
BLACKBOX_NAME="fds-monitor01-blackbox"
RECEIVER_HOST_CONFIG=Path("/etc/fds/monitor01/receiver/prometheus.yml")
RECEIVER_HOST_DATA=Path("/var/lib/fds/monitor01/receiver")
BLACKBOX_HOST_CONFIG=Path("/etc/fds/monitor01/blackbox/blackbox.yml")
NGINX_NAME="fds-monitor01-nginx"
NGINX_LISTEN="10.250.10.30:8443"
NGINX_HOST_CONFIG=Path("/etc/fds/monitor01/nginx/nginx.conf")
NGINX_HOST_HTPASSWD=Path("/etc/fds/monitor01/nginx/htpasswd")
NGINX_HOST_CERT=Path("/etc/fds/monitor01/tls/monitor01.crt")
NGINX_HOST_KEY=Path("/etc/fds/pki/monitor01/request/monitor01.key")
IMAGE_RE=re.compile(r"^10\.1\.93\.54/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$")
CONFIG_RE=re.compile(r"^sha256:([0-9a-f]{64})$")

class Stop(RuntimeError): pass

def run(argv, check=True):
    p=subprocess.run(argv,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=False)
    if check and p.returncode!=0:
        raise Stop(f"command failed rc={p.returncode}: {argv!r}\n{p.stderr.strip()}")
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

# Gate F A안(#17 5924380025): docker-archive 전달본은 local RepoDigest가 새로 계산되므로
# 동일성은 승인 Harbor manifest의 config.digest = 로컬 이미지 ID로 판정한다.
# 실행은 그 이미지 ID + --pull=never로만 하고, 불일치·미적재면 STOP한다.
def resolve_local_image(podman,image,config_digest,label):
    ref=require_digest(image,f"{label} image")
    m=CONFIG_RE.fullmatch(config_digest)
    if not m: raise Stop(f"{label} config digest must be sha256:<64hex>")
    image_id=m.group(1)
    p=run([podman,"image","inspect","--format","json",image_id],check=False)
    if p.returncode!=0:
        raise Stop(f"{label} image with config {config_digest} is not loaded locally (no pull attempted)")
    try: data=json.loads(p.stdout)
    except ValueError: raise Stop(f"{label} image inspect output is not JSON")
    if not isinstance(data,list) or len(data)!=1:
        raise Stop(f"{label} image inspect must return exactly one image")
    got=str(data[0].get("Id",""))
    if got!=image_id:
        raise Stop(f"{label} local image ID {got!r} does not match expected config digest {config_digest}")
    return {"approved_harbor_digest":ref,"expected_config_digest":config_digest,"local_image_id":f"sha256:{got}",
            "local_repo_digests_transfer_only":data[0].get("RepoDigests") or [],
            "rootfs_layers":(data[0].get("RootFS") or {}).get("Layers") or []}

def exists(podman,name):
    return run([podman,"container","exists",name],check=False).returncode==0

def remove(podman,name):
    if exists(podman,name): run([podman,"rm","-f",name],check=False)

LISTEN_WAIT_SECONDS=30
LOCAL_LISTENERS={19090:"127.0.0.1:19090",9115:"127.0.0.1:9115"}

# podman run -d는 프로세스가 포트를 열기 전에 돌아온다. 미기동은 최대 30초 재확인,
# 정해진 주소 밖 listen은 기다리지 않고 바로 STOP한다.
def verify(ss,wait=LISTEN_WAIT_SECONDS,expected=LOCAL_LISTENERS):
    deadline=time.monotonic()+wait
    while True:
        lines=run([ss,"-ltnH"]).stdout.splitlines()
        out,missing={},[]
        for port,addr in expected.items():
            matches=[x for x in lines if f":{port}" in x]
            bad=[x for x in matches if addr not in x]
            if bad: raise Stop(f"listener {port} is not bound only to {addr}: {bad}")
            if matches: out[str(port)]=matches
            else: missing.append(port)
        if not missing: return out
        if time.monotonic()>=deadline: raise Stop(f"listener {missing} missing after {wait}s")
        time.sleep(1)

def start(args):
    podman,ss=require_identity()
    rimg=resolve_local_image(podman,args.receiver_image,args.receiver_config_digest,"receiver")
    bimg=resolve_local_image(podman,args.blackbox_image,args.blackbox_config_digest,"blackbox")
    ri,bi=rimg["local_image_id"][len("sha256:"):],bimg["local_image_id"][len("sha256:"):]
    for p in (RECEIVER_HOST_CONFIG,BLACKBOX_HOST_CONFIG):
        if not p.is_file() or p.is_symlink(): raise Stop(f"required config missing/unsafe: {p}")
    if not RECEIVER_HOST_DATA.is_dir() or RECEIVER_HOST_DATA.is_symlink():
        raise Stop(f"receiver data directory missing/unsafe: {RECEIVER_HOST_DATA}")
    for name in (RECEIVER_NAME,BLACKBOX_NAME):
        if exists(podman,name): raise Stop(f"container already exists: {name}")
    rc=[podman,"run","-d","--pull=never","--name",RECEIVER_NAME,"--network","host","--security-opt","no-new-privileges","--cap-drop","all",
        "-v",f"{RECEIVER_HOST_CONFIG}:/etc/prometheus/prometheus.yml:ro,Z",
        "-v",f"{RECEIVER_HOST_DATA}:/prometheus:Z",ri,
        "--config.file=/etc/prometheus/prometheus.yml","--storage.tsdb.path=/prometheus",
        "--web.listen-address=127.0.0.1:19090","--web.enable-remote-write-receiver"]
    bc=[podman,"run","-d","--pull=never","--name",BLACKBOX_NAME,"--network","host","--security-opt","no-new-privileges","--cap-drop","all",
        "-v",f"{BLACKBOX_HOST_CONFIG}:/etc/blackbox/blackbox.yml:ro,Z",bi,
        "--config.file=/etc/blackbox/blackbox.yml","--web.listen-address=127.0.0.1:9115"]
    started=[]
    try:
        run(rc); started.append(RECEIVER_NAME)
        run(bc); started.append(BLACKBOX_NAME)
        listeners=verify(ss)
    except BaseException:
        for n in reversed(started):
            logs=run([podman,"logs","--tail","50",n],check=False)
            print(f"--- {n} logs (last 50) ---\n{logs.stdout}{logs.stderr}",file=sys.stderr)
            remove(podman,n)
        raise
    print(json.dumps({"status":"LOCAL_SERVICES_STARTED","runtime":"RUNNING_NOT_ACCEPTED","containers":started,
                      "listeners":listeners,"receiver_image":rimg,"blackbox_image":bimg},ensure_ascii=False,indent=2))

def verify_image(args):
    podman,_=require_identity()
    out=resolve_local_image(podman,args.image,args.config_digest,"image")
    print(json.dumps({"status":"IMAGE_IDENTITY_MATCH","runtime":"NOT_STARTED",**out},ensure_ascii=False,indent=2))

def stop(_args):
    podman,_=require_identity()
    for n in (BLACKBOX_NAME,RECEIVER_NAME): remove(podman,n)
    print(json.dumps({"status":"LOCAL_SERVICES_STOPPED","containers":[BLACKBOX_NAME,RECEIVER_NAME]},indent=2))

def nginx_files():
    for p in (NGINX_HOST_CONFIG,NGINX_HOST_HTPASSWD,NGINX_HOST_CERT,NGINX_HOST_KEY):
        if not p.is_file() or p.is_symlink(): raise Stop(f"required nginx file missing/unsafe: {p}")

# 키는 relabel하지 않는다(:Z 없음). container_read_certs + 키 1개 읽기 ACL로 읽는다(#17 5927558258·5927596564).
# 인증서·htpasswd·키는 호스트와 같은 경로로 마운트해 nginx.conf의 render_candidate 경로를 그대로 쓴다.
def nginx_run_args(image_id):
    return ["--pull=never","--security-opt","no-new-privileges","--cap-drop","all",
            "-v",f"{NGINX_HOST_CONFIG}:/etc/nginx/nginx.conf:ro,Z",
            "-v",f"{NGINX_HOST_HTPASSWD}:{NGINX_HOST_HTPASSWD}:ro,Z",
            "-v",f"{NGINX_HOST_CERT}:{NGINX_HOST_CERT}:ro,Z",
            "-v",f"{NGINX_HOST_KEY}:{NGINX_HOST_KEY}:ro",
            image_id,"-c","/etc/nginx/nginx.conf","-e","/dev/stderr"]

def nginx_image(podman,args):
    img=resolve_local_image(podman,args.image,args.config_digest,"nginx")
    nginx_files()
    return img,img["local_image_id"][len("sha256:"):]

def check_nginx(args):
    podman,_=require_identity()
    img,image_id=nginx_image(podman,args)
    if exists(podman,NGINX_NAME): raise Stop(f"{NGINX_NAME} already exists; check-nginx is a pre-start check")
    # nginx -t는 listen 주소 bind까지 시험한다. --network none에는 10.250.10.30이 없어 99로 실패하므로
    # start-nginx와 같은 host 네트워크로 시험한다(bind 후 바로 종료, 8443 외부 허용 없음).
    p=run([podman,"run","--rm","--network","host",*nginx_run_args(image_id),"-t"],check=False)
    if p.returncode!=0: raise Stop(f"nginx -t failed rc={p.returncode}\n{p.stdout}{p.stderr}")
    print(json.dumps({"status":"NGINX_CONFIG_OK","runtime":"NOT_STARTED","nginx_t":(p.stdout+p.stderr).strip(),
                      "nginx_image":img},ensure_ascii=False,indent=2))

def start_nginx(args):
    podman,ss=require_identity()
    img,image_id=nginx_image(podman,args)
    if exists(podman,NGINX_NAME): raise Stop(f"container already exists: {NGINX_NAME}")
    try:
        run([podman,"run","-d","--name",NGINX_NAME,"--network","host",*nginx_run_args(image_id),"-g","daemon off;"])
        listeners=verify(ss,expected={8443:NGINX_LISTEN})
    except BaseException:
        logs=run([podman,"logs","--tail","50",NGINX_NAME],check=False)
        print(f"--- {NGINX_NAME} logs (last 50) ---\n{logs.stdout}{logs.stderr}",file=sys.stderr)
        remove(podman,NGINX_NAME)
        raise
    print(json.dumps({"status":"NGINX_STARTED","runtime":"RUNNING_NOT_ACCEPTED","container":NGINX_NAME,
                      "listeners":listeners,"nginx_image":img},ensure_ascii=False,indent=2))

def stop_nginx(_args):
    podman,_=require_identity()
    remove(podman,NGINX_NAME)
    print(json.dumps({"status":"NGINX_STOPPED","container":NGINX_NAME},indent=2))

def main():
    p=argparse.ArgumentParser()
    sub=p.add_subparsers(dest="command",required=True)
    s=sub.add_parser("start")
    for opt in ("--receiver-image","--receiver-config-digest","--blackbox-image","--blackbox-config-digest"): s.add_argument(opt,required=True)
    s.set_defaults(func=start)
    v=sub.add_parser("verify-image"); v.add_argument("--image",required=True); v.add_argument("--config-digest",required=True); v.set_defaults(func=verify_image)
    t=sub.add_parser("stop"); t.set_defaults(func=stop)
    for name,func in (("check-nginx",check_nginx),("start-nginx",start_nginx)):
        n=sub.add_parser(name); n.add_argument("--image",required=True); n.add_argument("--config-digest",required=True); n.set_defaults(func=func)
    sn=sub.add_parser("stop-nginx"); sn.set_defaults(func=stop_nginx)
    a=p.parse_args(); a.func(a); return 0

if __name__=="__main__":
    try: raise SystemExit(main())
    except (Stop,KeyboardInterrupt) as exc:
        print(f"STOP: {type(exc).__name__}: {exc}",file=sys.stderr); raise SystemExit(2)
