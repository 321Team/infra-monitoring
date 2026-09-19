"""Render review candidates only. No SSH, key reads, installs or service changes."""
import argparse
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys

SCHEMA = "fds.monitor01-tls-candidate.v1"
FIELDS = {
    "schema", "receiver_port", "source_ipv4", "leaf_file", "key_file",
    "root_file_on_sender", "nginx_password_file", "sender_username",
    "sender_password_file", "receiver_config_dir", "receiver_data_dir",
}
PATH_FIELDS = FIELDS & {
    "leaf_file", "key_file", "root_file_on_sender", "nginx_password_file",
    "sender_password_file", "receiver_config_dir", "receiver_data_dir",
}


def validate(data):
    """Reject unknown fields, unfilled inputs and configuration injection."""
    if not isinstance(data, dict) or set(data) != FIELDS:
        raise ValueError("input field set differs from the public example")
    if data["schema"] != SCHEMA:
        raise ValueError("unsupported schema")
    port = data["receiver_port"]
    if type(port) is not int or not 1024 <= port <= 65535 or port in (9090, 9115):
        raise ValueError("receiver_port: explicit unprivileged port required; reserve 9090/9115")
    sources = data["source_ipv4"]
    if not isinstance(sources, list) or not sources or len(sources) > 32:
        raise ValueError("source_ipv4: measured sender source addresses required")
    if any(not isinstance(value, str) for value in sources) or len(set(sources)) != len(sources):
        raise ValueError("source_ipv4: unique strings required")
    for value in sources:
        ip = ipaddress.IPv4Address(value)
        if not ip.is_private or any((ip.is_loopback, ip.is_unspecified, ip.is_multicast,
                                    ip.is_link_local, ip.is_reserved)):
            raise ValueError("source_ipv4: expected private unicast IPv4 host, without CIDR")
        if str(ip) != value:
            raise ValueError("source_ipv4: canonical address required")
    for name in PATH_FIELDS:
        value = data[name]
        if not isinstance(value, str) or not re.fullmatch(r"/[A-Za-z0-9_./-]+", value):
            raise ValueError(name + ": explicit absolute path required")
        path = PurePosixPath(value)
        if value == "/" or ".." in path.parts or str(path) != value:
            raise ValueError(name + ": normalized non-root path required")
    if len({data[name] for name in PATH_FIELDS}) != len(PATH_FIELDS):
        raise ValueError("credential, certificate and receiver paths must differ")
    user = data["sender_username"]
    if not isinstance(user, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", user):
        raise ValueError("sender_username: explicit non-secret account name required")
    return data


def json_text(value):
    # JSON is valid YAML and keeps user input out of template syntax.
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def render(data):
    d = validate(data)
    port = d["receiver_port"]
    allow = "\n".join("        allow " + ip + ";" for ip in d["source_ipv4"])
    nginx = f'''# REVIEW CANDIDATE: include inside the nginx http context.
# No request body, query string or Authorization header in this access log.
log_format fds_monitor01 '$remote_addr $request_method $uri $status';
server {{
    listen 10.250.10.30:443 ssl;
    server_name 10.250.10.30;
    ssl_certificate {d["leaf_file"]};
    ssl_certificate_key {d["key_file"]};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;
    access_log /var/log/nginx/fds-monitor01-access.log fds_monitor01;
    client_max_body_size 1m;

    location = /api/v1/write {{
        if ($request_method != POST) {{ return 405; }}
        if ($args != "") {{ return 400; }}
        satisfy all;
{allow}
        deny all;
        auth_basic "FDS monitor01 remote write";
        auth_basic_user_file {d["nginx_password_file"]};
        proxy_set_header Authorization "";
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:{port};
    }}
    location / {{ return 404; }}
}}
'''
    receiver = {
        "global": {"evaluation_interval": "15s"},
        "rule_files": [d["receiver_config_dir"] + "/watchdog.rules.json"],
        "scrape_configs": [],
    }
    sender = {"remote_write": [{
        "url": "https://10.250.10.30/api/v1/write",
        "follow_redirects": False,
        "tls_config": {"ca_file": d["root_file_on_sender"],
                       "insecure_skip_verify": False, "min_version": "TLS12"},
        "basic_auth": {"username": d["sender_username"],
                       "password_file": d["sender_password_file"]},
        "write_relabel_configs": [
            {"source_labels": ["__name__"], "regex": "fds_monitoring_heartbeat", "action": "keep"},
            {"regex": "__name__", "action": "labelkeep"},
        ],
    }]}
    heartbeat = {"groups": [{"name": "fds-monitoring-heartbeat", "interval": "15s",
                             "rules": [{"record": "fds_monitoring_heartbeat", "expr": "vector(1)"}]}]}
    watchdog = {"groups": [{"name": "fds-monitor01-watchdog", "interval": "15s", "rules": [{
        "alert": "FDSMonitoringHeartbeatMissing",
        "expr": "absent_over_time(fds_monitoring_heartbeat[5m])",
        "labels": {"severity": "critical"},
        "annotations": {"summary": "monitor01 has no in-cluster heartbeat samples in the last 5 minutes"},
    }]}]}
    argv = [
        "--web.listen-address=127.0.0.1:" + str(port),
        "--web.enable-remote-write-receiver",
        "--config.file=" + d["receiver_config_dir"] + "/receiver.prometheus.json",
        "--storage.tsdb.path=" + d["receiver_data_dir"],
    ]
    return {
        "nginx-monitor01.conf": nginx,
        "receiver.prometheus.json": json_text(receiver),
        "receiver.argv.json": json_text(argv),
        "sender.remote-write.fragment.json": json_text(sender),
        "sender.heartbeat.rules.json": json_text(heartbeat),
        "watchdog.rules.json": json_text(watchdog),
        "CANDIDATE.json": json_text({"schema": SCHEMA, "state": "RENDERED_NOT_DEPLOYED",
                                     "payload_scope": "heartbeat-only",
                                     "remaining": ["Lead integration inputs and accepted versions/digests",
                                                   "service/container integration and receiver storage sizing",
                                                   "Secret mounts, permissions, SELinux and host firewall",
                                                   "native parser and actual positive/negative/rollback tests",
                                                   "Blackbox integration and failure/recovery acceptance"]}),
    }


def write_new_directory(files, target):
    target = Path(target)
    # Only an existing canonical parent is accepted. Never overwrite a directory/file.
    parent = target.parent.resolve(strict=True)
    if target.parent.absolute() != parent or target.name in ("", ".", ".."):
        raise ValueError("output requires a canonical existing parent directory")
    target = parent / target.name
    target.mkdir(mode=0o700)
    for name, content in files.items():
        with (target / name).open("x", encoding="utf-8") as stream:
            os.chmod(target / name, 0o600)
            stream.write(content)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", required=True, type=Path)
    parser.add_argument("--output-dir", type=Path, help="new local candidate directory; never a live configuration path")
    args = parser.parse_args(argv)
    try:
        data = json.loads(args.inputs.read_text(encoding="utf-8"))
        files = render(data)
        if args.output_dir:
            write_new_directory(files, args.output_dir)
            print("CANDIDATE_RENDERED_NOT_DEPLOYED")
        else:
            print("INPUTS_COMPLETE_NOT_RUNTIME_VERIFIED")
        return 0
    except (ValueError, OSError) as error:
        print("STOP: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
