"""Unit and integration tests for validate-observability.py."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import runpy
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "validate-observability.py"
spec = importlib.util.spec_from_file_location("validate_observability", SCRIPT)
validator = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(validator)


def monitoring_application(name: str = "monitoring", values: dict | None = None) -> dict:
    if values is None:
        values = {
            "prometheus": {
                "prometheusSpec": {
                    "ruleSelector": {"matchLabels": {"release": "monitoring"}},
                    "serviceMonitorSelector": {"matchLabels": {"release": "monitoring"}},
                }
            },
            "grafana": {"sidecar": {"dashboards": {"label": "grafana_dashboard", "labelValue": 1}}},
        }
    return {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "Application",
        "metadata": {"name": name},
        "spec": {"source": {"helm": {"values": yaml.safe_dump(values)}}},
    }


def valid_resources() -> list[dict]:
    rules = [
        {"alert": alert, "expr": "vector(1)"}
        for alert in sorted(validator.EXPECTED_SLO_ALERTS)
    ]
    rules.append({"record": "elastiflix:test", "expr": "vector(1)"})
    return [
        {
            "apiVersion": "monitoring.coreos.com/v1",
            "kind": "ServiceMonitor",
            "metadata": {"name": "backend", "labels": {"release": "monitoring"}},
        },
        monitoring_application(),
        monitoring_application(),
        {
            "apiVersion": "monitoring.coreos.com/v1",
            "kind": "PrometheusRule",
            "metadata": {"name": "slo", "labels": {"release": "monitoring"}},
            "spec": {"groups": [{"name": "slo", "rules": rules}]},
        },
        {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "dashboard", "labels": {"grafana_dashboard": "1"}},
            "data": {
                "slo.json": json.dumps(
                    {
                        "title": "SLO",
                        "panels": [
                            {"title": "Availability", "targets": [{"expr": "vector(1)"}, {}]},
                            {"title": "Text panel"},
                        ],
                    }
                ),
                "readme.txt": "not a dashboard",
            },
        },
        {"kind": "ConfigMap", "metadata": {"name": "unlabelled-dashboard"}},
        "a non-resource scalar document",
    ]


class DocumentsTests(unittest.TestCase):
    def test_yaml_documents_flatten_lists_and_skip_null_documents(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "resources.yaml"
            path.write_text("- kind: One\n- null\n---\nkind: Two\n---\nnull\n", encoding="utf-8")
            self.assertEqual(
                list(validator.documents(path)),
                [{"kind": "One"}, {"kind": "Two"}],
            )

    def test_main_validates_repository_manifests(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(validator.main(), 0)
        self.assertRegex(output.getvalue(), r"Validated [1-9][0-9]* Kubernetes YAML files")

    def test_promql_validation_accepts_valid_and_rejects_invalid_expression(self):
        validator.validate_promql("sum(rate(http_requests_total[5m]))", "unit-test")
        with self.assertRaisesRegex(ValueError, "Invalid PromQL in unit-test"):
            validator.validate_promql("sum(rate(", "unit-test")

    def test_main_cli_success_and_failure_reporting(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as result:
                runpy.run_path(str(SCRIPT), run_name="__main__")
        self.assertEqual(result.exception.code, 0)
        self.assertRegex(output.getvalue(), r"Validated [1-9][0-9]* Kubernetes YAML files")

        errors = io.StringIO()
        with mock.patch.object(Path, "rglob", side_effect=OSError("fixture read failed")):
            with contextlib.redirect_stderr(errors):
                with self.assertRaises(SystemExit) as result:
                    runpy.run_path(str(SCRIPT), run_name="__main__")
        self.assertEqual(result.exception.code, 1)
        self.assertIn("Observability validation failed: fixture read failed", errors.getvalue())


class MainValidationTests(unittest.TestCase):
    def run_with(self, resources: list[dict]) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "manifest.yaml").write_text(
                yaml.safe_dump_all(resources, sort_keys=False), encoding="utf-8"
            )
            with mock.patch.object(validator, "KUBERNETES", root):
                validator.main()

    def assert_invalid(self, resources: list[dict], message: str) -> None:
        with self.assertRaisesRegex(ValueError, message):
            self.run_with(resources)

    def test_valid_fixture_passes_and_non_json_dashboard_data_is_ignored(self):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "manifest.yaml").write_text(
                yaml.safe_dump_all(valid_resources(), sort_keys=False), encoding="utf-8"
            )
            with mock.patch.object(validator, "KUBERNETES", root), contextlib.redirect_stdout(output):
                self.assertEqual(validator.main(), 0)
        self.assertIn("4 Prometheus rules", output.getvalue())
        self.assertIn("1 Grafana dashboards", output.getvalue())

    def test_rejects_servicemonitor_without_matching_label(self):
        resources = valid_resources()
        resources[0]["metadata"]["labels"] = {}
        self.assert_invalid(resources, "ServiceMonitor lacks release=monitoring")

    def test_rejects_monitoring_application_with_incorrect_prometheus_selector(self):
        resources = valid_resources()
        values = yaml.safe_load(resources[1]["spec"]["source"]["helm"]["values"])
        values["prometheus"]["prometheusSpec"]["ruleSelector"]["matchLabels"]["release"] = "other"
        resources[1]["spec"]["source"]["helm"]["values"] = yaml.safe_dump(values)
        self.assert_invalid(resources, "ruleSelector must select release=monitoring")

    def test_rejects_monitoring_application_with_incorrect_dashboard_selector(self):
        resources = valid_resources()
        values = yaml.safe_load(resources[1]["spec"]["source"]["helm"]["values"])
        values["grafana"]["sidecar"]["dashboards"]["labelValue"] = 0
        resources[1]["spec"]["source"]["helm"]["values"] = yaml.safe_dump(values)
        self.assert_invalid(resources, "Grafana sidecar dashboard selector")

    def test_ignores_non_monitoring_applications(self):
        resources = valid_resources()
        resources[1]["metadata"]["name"] = "application"
        resources[2]["metadata"]["name"] = "another-application"
        self.assert_invalid(resources, "Expected local and EKS monitoring Applications")

    def test_rejects_prometheus_rule_without_matching_label(self):
        resources = valid_resources()
        resources[3]["metadata"]["labels"] = {}
        self.assert_invalid(resources, "PrometheusRule lacks release=monitoring")

    def test_rejects_prometheus_rule_group_without_name_or_rules(self):
        for group in ({"name": "", "rules": [{"alert": "x", "expr": "vector(1)"}]},
                      {"name": "slo", "rules": []}):
            with self.subTest(group=group):
                resources = valid_resources()
                resources[3]["spec"]["groups"] = [group]
                self.assert_invalid(resources, "PrometheusRule group needs a name and rules")

    def test_rejects_rule_with_neither_or_both_alert_and_record(self):
        for rule in ({"expr": "vector(1)"}, {"alert": "x", "record": "x:y", "expr": "vector(1)"}):
            with self.subTest(rule=rule):
                resources = valid_resources()
                resources[3]["spec"]["groups"][0]["rules"] = [rule]
                self.assert_invalid(resources, "each rule must declare exactly one of alert or record")

    def test_rejects_rule_without_expression_and_invalid_promql(self):
        missing_expr = valid_resources()
        missing_expr[3]["spec"]["groups"][0]["rules"] = [{"alert": "x"}]
        self.assert_invalid(missing_expr, "Prometheus rule has no expr")

        invalid_expr = valid_resources()
        invalid_expr[3]["spec"]["groups"][0]["rules"] = [{"alert": "x", "expr": "sum(rate("}]
        self.assert_invalid(invalid_expr, "Invalid PromQL")

    def test_rejects_invalid_dashboard_structure_and_promql(self):
        for dashboard in ({"panels": []}, {"title": "SLO", "panels": "not-a-list"}):
            with self.subTest(dashboard=dashboard):
                resources = valid_resources()
                resources[4]["data"]["slo.json"] = json.dumps(dashboard)
                self.assert_invalid(resources, "invalid Grafana dashboard structure")

        resources = valid_resources()
        resources[4]["data"]["slo.json"] = json.dumps(
            {"title": "SLO", "panels": [{"title": "Bad", "targets": [{"expr": "sum(rate("}]}]}
        )
        self.assert_invalid(resources, "Invalid PromQL")

    def test_rejects_missing_expected_alerts_applications_and_service_monitors(self):
        self.assert_invalid([], "Missing expected SLO alerts")

        without_one_app = valid_resources()
        without_one_app.pop(2)
        self.assert_invalid(without_one_app, "Expected local and EKS monitoring Applications")

        without_monitor = valid_resources()
        without_monitor.pop(0)
        self.assert_invalid(without_monitor, "No ServiceMonitor resources were found")


if __name__ == "__main__":
    unittest.main()
