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


if __name__ == "__main__":
    unittest.main()
