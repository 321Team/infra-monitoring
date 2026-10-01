import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import types
import unittest
from unittest import mock

try:
    import pwd  # noqa: F401
except ImportError:  # 개발 PC(Windows) 실행용. CI(Linux)는 실제 pwd를 쓴다.
    sys.modules["pwd"] = types.SimpleNamespace(getpwuid=lambda uid: None)

spec = importlib.util.spec_from_file_location("launcher", Path(__file__).with_name("runtime_launch_local.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Synthetic test values. Not approved deployment digests.
CFG_R = "a" * 64
CFG_B = "b" * 64
REF_R = "10.1.93.54/fds/prometheus@sha256:" + "1" * 64
REF_B = "10.1.93.54/fds/blackbox-exporter@sha256:" + "2" * 64


def proc(rc=0, out=""):
    return subprocess.CompletedProcess([], rc, out, "")


def inspect_out(image_id, repo_digests=("10.1.93.54/fds/x@sha256:" + "9" * 64,)):
    return json.dumps([{"Id": image_id, "RepoDigests": list(repo_digests),
                        "RootFS": {"Type": "layers", "Layers": ["sha256:" + "c" * 64]}}])


class FakePodman:
    """podman 호출을 기록하고 image inspect 결과만 돌려준다."""

    def __init__(self, images):
        self.images = images
        self.calls = []

    def __call__(self, argv, check=True):
        self.calls.append(list(argv))
        if argv[1:4] == ["image", "inspect", "--format"]:
            key = argv[-1]
            if key not in self.images:
                return proc(125)
            return proc(0, self.images[key])
        return proc(0)


class ImageRefTests(unittest.TestCase):
    def test_approved_harbor_digest_accepted(self):
        self.assertEqual(m.require_digest(REF_R, "x"), REF_R)

    def test_non_digest_refs_rejected(self):
        for bad in ("10.1.93.54/fds/prometheus:v3.15.0",
                    "docker.io/prom/prometheus@sha256:" + "1" * 64,
                    "10x1x93x54/fds/prometheus@sha256:" + "1" * 64,
                    "10.1.93.54/fds/prometheus@sha256:" + "A" * 64):
            with self.assertRaises(m.Stop):
                m.require_digest(bad, "x")


class ResolveTests(unittest.TestCase):
    def test_match_returns_image_id_and_keeps_repodigest_as_record_only(self):
        fake = FakePodman({CFG_R: inspect_out(CFG_R)})
        with mock.patch.object(m, "run", fake):
            out = m.resolve_local_image("podman", REF_R, "sha256:" + CFG_R, "receiver")
        self.assertEqual(out["local_image_id"], "sha256:" + CFG_R)
        self.assertEqual(out["approved_harbor_digest"], REF_R)
        self.assertEqual(len(out["local_repo_digests_transfer_only"]), 1)
        self.assertEqual(fake.calls, [["podman", "image", "inspect", "--format", "json", CFG_R]])

    def test_id_mismatch_stops(self):
        fake = FakePodman({CFG_R: inspect_out("d" * 64)})
        with mock.patch.object(m, "run", fake), self.assertRaises(m.Stop):
            m.resolve_local_image("podman", REF_R, "sha256:" + CFG_R, "receiver")

    def test_not_loaded_stops_without_pull(self):
        fake = FakePodman({})
        with mock.patch.object(m, "run", fake), self.assertRaises(m.Stop):
            m.resolve_local_image("podman", REF_R, "sha256:" + CFG_R, "receiver")
        self.assertFalse(any("pull" in " ".join(c) for c in fake.calls))

    def test_bad_config_digest_stops_before_podman(self):
        fake = FakePodman({CFG_R: inspect_out(CFG_R)})
        for bad in (CFG_R, "sha256:" + CFG_R[:12], "sha512:" + CFG_R, "sha256:" + "A" * 64):
            with mock.patch.object(m, "run", fake), self.assertRaises(m.Stop):
                m.resolve_local_image("podman", REF_R, bad, "receiver")
        self.assertEqual(fake.calls, [])

    def test_inspect_must_return_exactly_one_image(self):
        for out in ("[]", json.dumps([{"Id": CFG_R}, {"Id": CFG_R}]), "not-json"):
            fake = FakePodman({CFG_R: out})
            with mock.patch.object(m, "run", fake), self.assertRaises(m.Stop):
                m.resolve_local_image("podman", REF_R, "sha256:" + CFG_R, "receiver")


class StartTests(unittest.TestCase):
    def args(self, **kw):
        a = dict(receiver_image=REF_R, receiver_config_digest="sha256:" + CFG_R,
                 blackbox_image=REF_B, blackbox_config_digest="sha256:" + CFG_B)
        a.update(kw)
        return types.SimpleNamespace(**a)

    def start(self, fake, args):
        fs = mock.patch.multiple(m.Path, is_file=lambda self: True, is_dir=lambda self: True,
                                 is_symlink=lambda self: False)
        with fs, mock.patch.object(m, "run", fake), \
                mock.patch.object(m, "require_identity", return_value=("podman", "ss")), \
                mock.patch.object(m, "exists", return_value=False), \
                mock.patch.object(m, "verify", return_value={}), \
                mock.patch("builtins.print"):
            m.start(args)

    def test_runs_by_image_id_with_pull_never(self):
        fake = FakePodman({CFG_R: inspect_out(CFG_R), CFG_B: inspect_out(CFG_B)})
        self.start(fake, self.args())
        runs = [c for c in fake.calls if c[1] == "run"]
        self.assertEqual(len(runs), 2)
        for argv, image_id, ref in ((runs[0], CFG_R, REF_R), (runs[1], CFG_B, REF_B)):
            self.assertIn("--pull=never", argv)
            self.assertIn(image_id, argv)
            self.assertLess(argv.index("--pull=never"), argv.index(image_id))
            self.assertNotIn(ref, argv)

    def test_blackbox_mismatch_stops_before_any_run(self):
        fake = FakePodman({CFG_R: inspect_out(CFG_R), CFG_B: inspect_out("e" * 64)})
        with self.assertRaises(m.Stop):
            self.start(fake, self.args())
        self.assertFalse(any(c[1] == "run" for c in fake.calls))


LISTEN_OK = ["LISTEN 0 4096 127.0.0.1:19090 0.0.0.0:*", "LISTEN 0 4096 127.0.0.1:9115 0.0.0.0:*"]


class VerifyTests(unittest.TestCase):
    def ss_seq(self, *outputs):
        it = iter(outputs)
        return lambda argv, check=True: proc(0, "\n".join(next(it)))

    def test_waits_until_listeners_appear(self):
        seq = self.ss_seq([], [LISTEN_OK[1]], LISTEN_OK)
        with mock.patch.object(m, "run", seq), mock.patch.object(m.time, "sleep") as sl:
            out = m.verify("ss", wait=30)
        self.assertEqual(sorted(out), ["19090", "9115"])
        self.assertEqual(sl.call_count, 2)

    def test_non_localhost_stops_without_waiting(self):
        seq = self.ss_seq(["LISTEN 0 4096 0.0.0.0:19090 0.0.0.0:*"])
        with mock.patch.object(m, "run", seq), mock.patch.object(m.time, "sleep") as sl, \
                self.assertRaises(m.Stop):
            m.verify("ss", wait=30)
        sl.assert_not_called()

    def test_missing_after_deadline_stops(self):
        clock = iter([0, 0, 31])
        with mock.patch.object(m, "run", lambda argv, check=True: proc(0, "")), \
                mock.patch.object(m.time, "monotonic", lambda: next(clock)), \
                mock.patch.object(m.time, "sleep"), self.assertRaises(m.Stop):
            m.verify("ss", wait=30)

    def test_start_failure_dumps_logs_before_remove(self):
        fake = FakePodman({CFG_R: inspect_out(CFG_R), CFG_B: inspect_out(CFG_B)})
        removed = []
        fs = mock.patch.multiple(m.Path, is_file=lambda self: True, is_dir=lambda self: True,
                                 is_symlink=lambda self: False)
        with fs, mock.patch.object(m, "run", fake), \
                mock.patch.object(m, "require_identity", return_value=("podman", "ss")), \
                mock.patch.object(m, "exists", return_value=False), \
                mock.patch.object(m, "remove", lambda p, n: removed.append(n)), \
                mock.patch.object(m, "verify", side_effect=m.Stop("listener [19090] missing after 30s")), \
                mock.patch("sys.stderr"), self.assertRaises(m.Stop):
            m.start(StartTests.args(None))
        logs = [c[-1] for c in fake.calls if c[1] == "logs"]
        self.assertEqual(logs, [m.BLACKBOX_NAME, m.RECEIVER_NAME])
        self.assertEqual(removed, [m.BLACKBOX_NAME, m.RECEIVER_NAME])


CFG_N = "c" * 64
REF_N = "10.1.93.54/fds/nginx@sha256:" + "3" * 64


class NginxTests(unittest.TestCase):
    def args(self):
        return types.SimpleNamespace(image=REF_N, config_digest="sha256:" + CFG_N)

    def patched(self, fake, verify=None):
        fs = mock.patch.multiple(m.Path, is_file=lambda self: True, is_symlink=lambda self: False)
        ctx = [fs, mock.patch.object(m, "run", fake),
               mock.patch.object(m, "require_identity", return_value=("podman", "ss")),
               mock.patch.object(m, "exists", return_value=False), mock.patch("builtins.print"),
               mock.patch("sys.stderr")]
        if verify is not None:
            ctx.append(mock.patch.object(m, "verify", verify))
        return ctx

    def run_with(self, ctx, func):
        from contextlib import ExitStack
        with ExitStack() as st:
            for c in ctx:
                st.enter_context(c)
            func(self.args())

    def test_conf_server_block_is_renderer_output_with_two_changes(self):
        rspec = importlib.util.spec_from_file_location("rc", Path(__file__).with_name("render_candidate.py"))
        rc = importlib.util.module_from_spec(rspec)
        rspec.loader.exec_module(rc)
        inputs = json.loads(Path(__file__).with_name("inputs.fds.json").read_text(encoding="utf-8"))
        rendered = rc.render(inputs)["nginx-monitor01.conf"].splitlines()[1:]
        want = [l.replace("listen 10.250.10.30:443 ssl;", "listen 10.250.10.30:8443 ssl;")
                 .replace("access_log /var/log/nginx/fds-monitor01-access.log fds_monitor01;",
                          "access_log /dev/stdout fds_monitor01;") for l in rendered]
        conf = Path(__file__).with_name("nginx").joinpath("nginx.conf").read_text(encoding="utf-8").splitlines()
        block = conf[conf.index("    # BEGIN render_candidate server") + 1:conf.index("    # END render_candidate server")]
        self.assertEqual([l[4:] if l else l for l in block], want)
        self.assertIn("allow 10.1.93.108;", "\n".join(block))
        self.assertIn(f"listen {m.NGINX_LISTEN} ssl;", "\n".join(block))

    def test_start_runs_by_image_id_and_key_is_not_relabeled(self):
        fake = FakePodman({CFG_N: inspect_out(CFG_N)})
        seen = {}
        verify = lambda ss, expected=None, **kw: seen.setdefault("expected", expected) or {}
        self.run_with(self.patched(fake, verify), m.start_nginx)
        runs = [c for c in fake.calls if c[1] == "run"]
        self.assertEqual(len(runs), 1)
        argv = runs[0]
        self.assertIn("--pull=never", argv)
        self.assertLess(argv.index("--pull=never"), argv.index(CFG_N))
        self.assertNotIn(REF_N, argv)
        self.assertIn(f"{m.NGINX_HOST_KEY}:{m.NGINX_HOST_KEY}:ro", argv)
        self.assertFalse(any(str(m.NGINX_HOST_KEY) in a and "Z" in a.split(":")[-1] for a in argv))
        self.assertEqual(seen["expected"], {8443: m.NGINX_LISTEN})

    def test_image_mismatch_stops_before_run(self):
        fake = FakePodman({CFG_N: inspect_out("d" * 64)})
        with self.assertRaises(m.Stop):
            self.run_with(self.patched(fake), m.start_nginx)
        self.assertFalse(any(c[1] == "run" for c in fake.calls))

    def test_listener_failure_dumps_logs_and_removes(self):
        fake = FakePodman({CFG_N: inspect_out(CFG_N)})
        removed = []
        ctx = self.patched(fake, mock.Mock(side_effect=m.Stop("listener [8443] missing after 30s")))
        ctx.append(mock.patch.object(m, "remove", lambda p, n: removed.append(n)))
        with self.assertRaises(m.Stop):
            self.run_with(ctx, m.start_nginx)
        self.assertEqual([c[-1] for c in fake.calls if c[1] == "logs"], [m.NGINX_NAME])
        self.assertEqual(removed, [m.NGINX_NAME])

    def test_check_uses_no_network_and_stops_on_failure(self):
        class Fail(FakePodman):
            def __call__(self, argv, check=True):
                r = super().__call__(argv, check)
                return proc(1, "") if argv[1] == "run" else r
        fake = Fail({CFG_N: inspect_out(CFG_N)})
        with self.assertRaises(m.Stop):
            self.run_with(self.patched(fake), m.check_nginx)
        argv = [c for c in fake.calls if c[1] == "run"][0]
        self.assertEqual(argv[argv.index("--network") + 1], "none")
        self.assertEqual(argv[-1], "-t")

    def test_listen_on_other_address_stops_without_waiting(self):
        out = "LISTEN 0 511 0.0.0.0:8443 0.0.0.0:*"
        with mock.patch.object(m, "run", lambda argv, check=True: proc(0, out)), \
                mock.patch.object(m.time, "sleep") as sl, self.assertRaises(m.Stop):
            m.verify("ss", wait=30, expected={8443: m.NGINX_LISTEN})
        sl.assert_not_called()


if __name__ == "__main__":
    unittest.main()
