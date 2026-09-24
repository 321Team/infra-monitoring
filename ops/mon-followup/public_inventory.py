#!/usr/bin/env python3
"""One-shot public metadata collector. No Secret GET, exec, probe or mutation."""
import datetime
import hashlib
import json
import os
import socket
import subprocess
import sys

NAMESPACES = ("monitoring-api", "monitoring-node")
SUPPORTED = {"Deployment", "DaemonSet", "Pod", "Service", "PersistentVolumeClaim", "ConfigMap", "NetworkPolicy"}


def pick(value, keys):
    return {key: value[key] for key in keys if key in value}


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def pod_spec(spec):
    """Never return env values, command/args, annotations or arbitrary spec."""
    result = {
        "serviceAccountName": spec.get("serviceAccountName", "default"),
        "hostNetwork": spec.get("hostNetwork", False),
        "imagePullSecrets": sorted(x["name"] for x in spec.get("imagePullSecrets", [])),
        "containers": [], "volumes": [],
    }
    for field in ("containers", "initContainers", "ephemeralContainers"):
        for container in spec.get(field, []):
            entry = pick(container, ("name", "image"))
            entry["class"] = field
            entry["mounts"] = [pick(x, ("name", "mountPath", "readOnly", "subPath", "subPathExpr"))
                               for x in container.get("volumeMounts", [])]
            entry["env_secret_refs"] = [pick(x["valueFrom"]["secretKeyRef"], ("name", "key", "optional"))
                                        for x in container.get("env", [])
                                        if "secretKeyRef" in x.get("valueFrom", {})]
            entry["env_from_secret_refs"] = [pick(x["secretRef"], ("name", "optional"))
                                             for x in container.get("envFrom", []) if "secretRef" in x]
            result["containers"].append(entry)
    for volume in spec.get("volumes", []):
        entry = {"name": volume["name"], "types": sorted(k for k in volume if k != "name")}
        for typ, fields in (("secret", ("secretName", "optional", "defaultMode", "items")),
                            ("configMap", ("name", "optional", "defaultMode", "items")),
                            ("persistentVolumeClaim", ("claimName", "readOnly"))):
            if typ in volume:
                entry[typ] = pick(volume[typ], fields)
                # API defaults do not count as source drift.
                entry[typ].pop("defaultMode", None)
        if "projected" in volume:
            entry["projected_refs"] = []
            for source in volume["projected"].get("sources", []):
                for typ in ("secret", "configMap"):
                    if typ in source:
                        entry["projected_refs"].append({"type": typ, **pick(source[typ], ("name", "items", "optional"))})
        result["volumes"].append(entry)
    return result


def project(obj):
    kind = obj.get("kind")
    if kind not in SUPPORTED:
        raise ValueError("unsupported kind")
    meta, spec = obj.get("metadata", {}), obj.get("spec", {})
    result = {"kind": kind, "namespace": meta.get("namespace", ""), "name": meta["name"]}
    if kind in ("Deployment", "DaemonSet", "Pod"):
        ps = spec if kind == "Pod" else spec["template"]["spec"]
        result["selected_spec"] = pod_spec(ps)
    elif kind == "ConfigMap":
        result["data_sha256"] = {key: digest(value) for key, value in sorted(obj.get("data", {}).items())}
        result["binary_keys"] = sorted(obj.get("binaryData", {}))
    elif kind == "Service":
        result["selected_spec"] = {"type": spec.get("type", "ClusterIP"),
                                   "selector": spec.get("selector", {}),
                                   "ports": [{"port": x["port"], "targetPort": x.get("targetPort", x["port"]),
                                              "protocol": x.get("protocol", "TCP"), **pick(x, ("name",))}
                                             for x in spec.get("ports", [])]}
    elif kind == "PersistentVolumeClaim":
        result["selected_spec"] = pick(spec, ("storageClassName", "accessModes", "resources", "volumeName"))
    elif kind == "NetworkPolicy":
        result["selected_spec"] = pick(spec, ("podSelector", "policyTypes", "ingress", "egress"))
    return result


def live_project(obj):
    result = project(obj)
    result["identity"] = pick(obj.get("metadata", {}), ("uid", "resourceVersion", "generation", "creationTimestamp"))
    status = obj.get("status", {})
    result["status"] = pick(status, ("phase", "replicas", "readyReplicas", "availableReplicas", "observedGeneration",
                                    "desiredNumberScheduled", "numberReady", "capacity", "podIP"))
    if obj["kind"] == "Pod":
        result["nodeName"] = obj.get("spec", {}).get("nodeName")
        result["containers_status"] = [pick(x, ("name", "imageID", "ready", "restartCount"))
                                       for x in status.get("containerStatuses", [])]
    if obj["kind"] == "Service":
        result["allocated"] = pick(obj["spec"], ("clusterIP", "externalIPs", "loadBalancerIP"))
        result["allocated"]["nodePorts"] = [x["nodePort"] for x in obj["spec"].get("ports", []) if "nodePort" in x]
    return result


def run(argv):
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=25, check=False)
    if proc.returncode:
        # Raw errors may contain credentials/config fragments; never persist them.
        raise RuntimeError("COMMAND_RC_" + str(proc.returncode))
    if len(proc.stdout) > 8 * 1024 * 1024:
        raise RuntimeError("OUTPUT_LIMIT")
    return proc.stdout


def get_list(path, kind):
    out = json.loads(run(["sudo", "-n", "kubectl", "--kubeconfig=/etc/kubernetes/admin.conf",
                          "--request-timeout=15s", "--cache-dir=/dev/null", "get", "--raw=" + path + "?limit=100"]))
    if out.get("metadata", {}).get("continue") or len(out.get("items", [])) > 100:
        raise RuntimeError("PAGINATION_LIMIT")
    if not isinstance(out.get("items"), list):
        raise RuntimeError("NOT_A_LIST")
    return [live_project({**obj, "kind": kind}) for obj in out["items"]]


def identify(expected):
    address = {"k8s-control01": "10.1.93.102", "monitor01": "10.250.10.30"}[expected]
    if socket.gethostname().split(".")[0] != expected:
        raise RuntimeError("HOST_MISMATCH")
    interfaces = json.loads(run(["ip", "-j", "-4", "address", "show"]))
    if not any(x.get("local") == address for iface in interfaces for x in iface.get("addr_info", [])):
        raise RuntimeError("ADDRESS_MISMATCH")


def collect(expected):
    report = {"schema": "fds.mon-followup.v1", "host": expected, "uid": os.getuid(),
              "started_at": datetime.datetime.now().astimezone().isoformat(), "checks": [], "objects": [],
              "collection_ok": True, "runtime_change": "NOT_RUN"}
    try:
        identify(expected)
    except Exception as error:
        report.update(collection_ok=False, identity_error=type(error).__name__)
        return report

    def check(label, func):
        entry = {"check": label, "at": datetime.datetime.now().astimezone().isoformat()}
        try:
            entry.update(ok=True, result=func())
        except Exception as error:
            entry.update(ok=False, error_type=type(error).__name__)
            report["collection_ok"] = False
        report["checks"].append(entry)
        return entry.get("result", [])

    if expected == "k8s-control01":
        for ns in NAMESPACES:
            resources = [("/api/v1", "pods", "Pod"), ("/api/v1", "services", "Service"),
                         ("/api/v1", "persistentvolumeclaims", "PersistentVolumeClaim"),
                         ("/apis/networking.k8s.io/v1", "networkpolicies", "NetworkPolicy")]
            resources += ([("/apis/apps/v1", "deployments", "Deployment"), ("/api/v1", "configmaps", "ConfigMap")]
                          if ns == "monitoring-api" else [("/apis/apps/v1", "daemonsets", "DaemonSet")])
            for api, resource, kind in resources:
                path = api + "/namespaces/" + ns + "/" + resource
                result = check(ns + "/" + resource, lambda p=path, k=kind: get_list(p, k))
                report["objects"].extend(result)
                # Avoid duplicate object payload in report.checks.
                if report["checks"][-1]["ok"]:
                    report["checks"][-1]["result"] = {"object_count": len(result)}
    else:
        commands = {
            "listeners": ["ss", "-H", "-lnt"],
            "service_states": ["systemctl", "show", "nginx.service", "prometheus.service", "blackbox-exporter.service",
                               "docker.service", "podman.service", "cockpit.socket", "--property=Id,LoadState,ActiveState,SubState,UnitFileState,User,Group,MainPID"],
            "capacity": ["df", "-P", "/", "/var/lib", "/home/server01_monitor"],
            "selinux": ["getenforce"],
        }
        for ip in ("10.1.93.105", "10.1.93.107", "10.1.93.108", "10.250.10.10"):
            commands["route_to_" + ip] = ["ip", "-4", "route", "get", ip]
        for path in ("/home/server01_monitor/monitor01.crt", "/home/server01_monitor/fds-root-ca.crt",
                     "/etc/fds/pki/monitor01/request/monitor01.key"):
            # Metadata only; no private key or credential bytes are read.
            commands["file_metadata_" + path] = ["sudo", "-n", "stat", "--printf=%F|%a|%u|%g|%C\\n", "--", path]
        for label, argv in commands.items():
            check(label, lambda a=argv: run(a).splitlines())
        for engine in ("docker", "podman"):
            check(engine + "_containers", lambda e=engine: run(["sudo", "-n", e, "ps", "-a", "--format",
                  "{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}"]).splitlines())
        report["scope_limits"] = ["Known unit names and rootful container engines only; custom/rootless services may be missed.",
                                  "Routes are candidates, not observed IF-06B sender addresses.",
                                  "Capacity paths are surveyed locations, not an approved receiver data directory."]
    report["finished_at"] = datetime.datetime.now().astimezone().isoformat()
    return report


def compare(report, reference):
    current = {(x["kind"], x["namespace"], x["name"]): x for x in report.get("objects", [])}
    results = []
    for expected in reference["objects"]:
        key = (expected["kind"], expected["namespace"], expected["name"])
        actual = current.get(key)
        fields = [k for k in expected if k not in ("kind", "namespace", "name")]
        different = fields if actual is None else [k for k in fields if expected[k] != actual.get(k)]
        results.append({"kind": key[0], "namespace": key[1], "name": key[2],
                        "result": "MISSING_OR_UNCOLLECTED" if actual is None else "DIFF" if different else "MATCH_SELECTED_FIELDS",
                        "different_fields": different})
    expected_keys = {(x["kind"], x["namespace"], x["name"]) for x in reference["objects"]}
    extras = [{"kind": k[0], "namespace": k[1], "name": k[2]} for k in sorted(current)
              if k not in expected_keys and k[0] != "Pod"]
    return {"reference_commit": reference["source_commit"], "collection_ok": report.get("collection_ok", False),
            "comparisons": results, "additional_objects": extras, "runtime_acceptance": "NOT_EVALUATED",
            "note": "Differences are review inputs, not instructions to restore main; defaults/order may differ. ConfigMap hashes are stored bytes, not loaded process configuration."}


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] in ("k8s-control01", "monitor01"):
        result = collect(sys.argv[1])
        print(json.dumps(result, ensure_ascii=False, indent=2))
        sys.exit(0 if result["collection_ok"] else 1)
    if len(sys.argv) == 4 and sys.argv[1] == "compare":
        with open(sys.argv[2], encoding="utf-8") as handle:
            report = json.load(handle)
        with open(sys.argv[3], encoding="utf-8") as handle:
            reference = json.load(handle)
        print(json.dumps(compare(report, reference), ensure_ascii=False, indent=2))
        sys.exit(0 if report.get("collection_ok") else 1)
    raise SystemExit("usage: public_inventory.py k8s-control01|monitor01 OR compare report.json source-reference.json")
