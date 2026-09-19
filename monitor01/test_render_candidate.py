import copy
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("candidate", Path(__file__).with_name("render_candidate.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class CandidateTests(unittest.TestCase):
    def setUp(self):
        # Synthetic, isolated unit-test values. Not measured deployment inputs.
        self.inputs = {
            "schema": m.SCHEMA, "receiver_port": 19090,
            "source_ipv4": ["10.99.0.7"],
            "leaf_file": "/test/pki/monitor01.crt", "key_file": "/test/pki/monitor01.key",
            "root_file_on_sender": "/test/sender/root.crt", "nginx_password_file": "/test/proxy/users",
            "sender_username": "test_sender", "sender_password_file": "/test/sender/password",
            "receiver_config_dir": "/test/receiver", "receiver_data_dir": "/test/data",
        }

    def test_unfilled_example_stops(self):
        with self.assertRaises(ValueError):
            m.render(json.loads(Path(__file__).with_name("inputs.example.json").read_text()))

    def test_unknown_field_stops(self):
        d = dict(self.inputs, password="never-accept-secret-value")
        with self.assertRaises(ValueError):
            m.render(d)

    def test_reserved_ports_and_bad_types_stop(self):
        for p in [None, True, "19090", 443, 9090, 9115, 65536]:
            with self.subTest(port=p), self.assertRaises(ValueError):
                m.render(dict(self.inputs, receiver_port=p))

    def test_unrestricted_and_forged_sources_stop(self):
        for src in [[], ["0.0.0.0/0"], ["10.0.0.0/8"], ["127.0.0.1"], ["::1"],
                    ["8.8.8.8"], ["224.0.0.1"], ["10.99.0.7; deny all"],
                    ["10.99.0.7", "10.99.0.7"], [None]]:
            with self.subTest(source=src), self.assertRaises(ValueError):
                m.render(dict(self.inputs, source_ipv4=src))

    def test_paths_cannot_inject_configuration(self):
        for name in m.PATH_FIELDS:
            for value in [None, "/", "relative", "/tmp/../etc/x", "/tmp//x", "/tmp/$x",
                          "/tmp/x; auth_basic off;", "/tmp/x\ninclude /tmp/bad;", "/tmp/x y"]:
                with self.subTest(field=name, value=value), self.assertRaises(ValueError):
                    m.render(dict(self.inputs, **{name: value}))

    def test_credentials_cannot_overlap_certificate(self):
        with self.assertRaises(ValueError):
            m.render(dict(self.inputs, nginx_password_file=self.inputs["key_file"]))

    def test_username_cannot_inject(self):
        for user in [None, "a:b", "a\npassword: x", "", "x" * 65]:
            with self.subTest(user=user), self.assertRaises(ValueError):
                m.render(dict(self.inputs, sender_username=user))

    def test_nginx_security_contract(self):
        text = m.render(self.inputs)["nginx-monitor01.conf"]
        for required in ["listen 10.250.10.30:443 ssl;", "location = /api/v1/write",
                         "TLSv1.2 TLSv1.3", "satisfy all;", "allow 10.99.0.7;", "deny all;",
                         "auth_basic_user_file /test/proxy/users;", "return 405;", "return 400;",
                         'proxy_set_header Authorization "";', "http://127.0.0.1:19090",
                         "location / { return 404; }"]:
            self.assertIn(required, text)
        self.assertNotIn("$http_authorization", text)
        self.assertNotIn("$request_body", text)

    def test_sender_only_heartbeat_and_no_business_labels(self):
        rw = json.loads(m.render(self.inputs)["sender.remote-write.fragment.json"])["remote_write"][0]
        keep, labels = rw["write_relabel_configs"]
        for metric in ["up", "fds_transaction_total", "fds_monitoring_heartbeat_extra"]:
            self.assertIsNone(re.fullmatch(keep["regex"], metric))
        self.assertIsNotNone(re.fullmatch(keep["regex"], "fds_monitoring_heartbeat"))
        for label in ["customer_id", "account_number", "job", "instance", "external_cluster"]:
            self.assertIsNone(re.fullmatch(labels["regex"], label))
        self.assertFalse(rw["tls_config"]["insecure_skip_verify"])
        self.assertFalse(rw["follow_redirects"])
        self.assertNotIn("password", rw["basic_auth"])

    def test_receiver_local_only_and_no_local_heartbeat(self):
        files = m.render(self.inputs)
        args = json.loads(files["receiver.argv.json"])
        self.assertIn("--web.listen-address=127.0.0.1:19090", args)
        self.assertIn("--web.enable-remote-write-receiver", args)
        self.assertFalse(any("enable-admin-api" in arg or "enable-lifecycle" in arg for arg in args))
        receiver = json.loads(files["receiver.prometheus.json"])
        self.assertEqual(receiver["scrape_configs"], [])
        rule = json.loads(files["watchdog.rules.json"])["groups"][0]["rules"][0]
        self.assertEqual(rule["expr"], "absent_over_time(fds_monitoring_heartbeat[5m])")
        self.assertNotIn("for", rule)
        self.assertNotIn("vector(1)", files["watchdog.rules.json"])

    def test_render_does_not_mutate_inputs(self):
        original = copy.deepcopy(self.inputs)
        self.assertEqual(m.render(self.inputs), m.render(self.inputs))
        self.assertEqual(original, self.inputs)

    def test_existing_directory_not_overwritten(self):
        with tempfile.TemporaryDirectory() as p:
            target = Path(p) / "out"
            m.write_new_directory(m.render(self.inputs), target)
            old = {f.name: f.read_bytes() for f in target.iterdir()}
            with self.assertRaises(FileExistsError):
                m.write_new_directory({"sentinel": "bad"}, target)
            self.assertEqual(old, {f.name: f.read_bytes() for f in target.iterdir()})
            self.assertEqual(target.stat().st_mode & 0o777, 0o700)
            self.assertTrue(all(f.stat().st_mode & 0o777 == 0o600 for f in target.iterdir()))

    def test_symlink_output_not_followed(self):
        with tempfile.TemporaryDirectory() as p:
            root = Path(p)
            (root / "link").symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                m.write_new_directory({"x": "bad"}, root / "link" / "new")
            self.assertFalse((root / "new").exists())


if __name__ == "__main__":
    unittest.main()
