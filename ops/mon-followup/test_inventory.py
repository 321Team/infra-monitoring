import copy
import json
import unittest
from unittest.mock import patch

import public_inventory as mod


class PublicInventoryTests(unittest.TestCase):
    def test_private_values_cannot_escape_projection(self):
        marker = "DO_NOT_PERSIST_TEST_SECRET_VALUE"
        pod = {"kind": "Pod", "metadata": {"name": "test", "namespace": "monitoring-api", "annotations": {"x": marker}},
               "spec": {"containers": [{"name": "am", "image": "example/am@sha256:test", "args": [marker],
                         "env": [{"name": "PRIVATE", "value": marker}, {"name": "REF", "valueFrom": {"secretKeyRef": {"name": "discord-webhook", "key": "webhook_url"}}}],
                         "volumeMounts": [{"name": "discord", "mountPath": "/etc/discord", "readOnly": True, "subPath": "webhook_url"}]}],
                        "volumes": [{"name": "discord", "secret": {"secretName": "discord-webhook"}}]},
               "status": {"containerStatuses": [{"name": "am", "imageID": "sha256:test", "ready": True,
                          "state": {"waiting": {"message": marker}}}]}}
        result = mod.live_project(pod)
        self.assertNotIn(marker, json.dumps(result))
        self.assertEqual(result["selected_spec"]["containers"][0]["mounts"][0]["subPath"], "webhook_url")
        self.assertIn("discord-webhook", json.dumps(result))

    def test_configmap_only_hashes_values(self):
        result = mod.project({"kind": "ConfigMap", "metadata": {"name": "am"}, "data": {"config": "synthetic private value"}})
        self.assertNotIn("synthetic private value", json.dumps(result))
        self.assertEqual(result["data_sha256"]["config"], mod.digest("synthetic private value"))

    def test_secret_objects_rejected(self):
        with self.assertRaises(ValueError):
            mod.project({"kind": "Secret", "metadata": {"name": "test"}, "data": {"x": "private"}})

    def test_pagination_not_reported_complete(self):
        with patch.object(mod, "run", return_value=json.dumps({"items": [], "metadata": {"continue": "next"}})):
            with self.assertRaisesRegex(RuntimeError, "PAGINATION_LIMIT"):
                mod.get_list("/api/v1/namespaces/monitoring-api/pods", "Pod")

    def test_host_mismatch_stops_before_api_calls(self):
        with patch.object(mod.socket, "gethostname", return_value="other-host"), patch.object(mod, "run") as command:
            report = mod.collect("k8s-control01")
        self.assertFalse(report["collection_ok"])
        command.assert_not_called()

    def test_collection_uses_only_bounded_reads_and_keeps_partial_results(self):
        calls = []
        def fake_run(argv):
            calls.append(argv)
            if "networkpolicies" in argv[-1]:
                raise RuntimeError("synthetic_sensitive_stderr")
            return json.dumps({"items": [], "metadata": {}})
        with patch.object(mod, "identify"), patch.object(mod, "run", side_effect=fake_run):
            report = mod.collect("k8s-control01")
        self.assertEqual(len(calls), 11)
        self.assertFalse(report["collection_ok"])
        self.assertNotIn("synthetic_sensitive_stderr", json.dumps(report))
        for argv in calls:
            self.assertIn("get", argv)
            self.assertTrue(argv[-1].endswith("?limit=100"))
            self.assertNotIn("secrets", argv[-1])
            self.assertIn("--cache-dir=/dev/null", argv)

    def test_missing_and_drift_are_not_remediation_or_pass(self):
        expected = mod.project({"kind": "ConfigMap", "metadata": {"name": "am", "namespace": "monitoring-api"}, "data": {"x": "screen-only"}})
        reference = {"source_commit": "a" * 40, "objects": [expected]}
        current = copy.deepcopy(expected)
        current["data_sha256"]["x"] = mod.digest("discord")
        report = mod.compare({"collection_ok": True, "objects": [current]}, reference)
        self.assertEqual(report["comparisons"][0]["result"], "DIFF")
        self.assertEqual(report["runtime_acceptance"], "NOT_EVALUATED")
        absent = mod.compare({"collection_ok": False, "objects": []}, reference)
        self.assertEqual(absent["comparisons"][0]["result"], "MISSING_OR_UNCOLLECTED")

    def test_metadata_reads_never_read_private_key_bytes(self):
        calls = []
        def fake_run(argv):
            calls.append(argv)
            return ""
        with patch.object(mod, "identify"), patch.object(mod, "run", side_effect=fake_run):
            mod.collect("monitor01")
        key_calls = [x for x in calls if any("monitor01.key" in arg for arg in x)]
        self.assertEqual(len(key_calls), 1)
        self.assertEqual(key_calls[0][:3], ["sudo", "-n", "stat"])
        self.assertFalse(any("restart" in x or "start" in x or "curl" in x for x in calls))


if __name__ == "__main__":
    unittest.main()
