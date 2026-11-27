"""Tests for scripts/validate-observability.py.

The validator is the only thing standing between a typo in a PromQL expression
and a dashboard that silently shows nothing, so its failure modes are tested
against temporary copies of the tree rather than the real manifests.
"""
from __future__ import annotations

import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR_PATH = ROOT / "scripts" / "validate-observability.py"

VALID_RULE = """\
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: test-rules
  namespace: monitoring
  labels:
    release: monitoring
spec:
  groups:
    - name: test.group
      rules:
        - record: elastiflix:test_ratio:rate5m
          expr: sum(rate(elastiflix_http_responses_total[5m]))
        - alert: ElastiflixSLOFastBurn
          expr: elastiflix:test_ratio:rate5m > 0.1
          labels:
            severity: critical
          annotations:
            summary: summary
            runbook_url: https://github.com/An619/Elastiflix/blob/main/docs/runbooks/elastiflix-availability.md
        - alert: ElastiflixSLOSlowBurn
          expr: elastiflix:test_ratio:rate5m > 0.1
          labels:
            severity: warning
          annotations:
            summary: summary
            runbook_url: https://github.com/An619/Elastiflix/blob/main/docs/runbooks/elastiflix-availability.md
        - alert: ElastiflixSLOObjectiveMiss
          expr: elastiflix:test_ratio:rate5m > 0.1
          labels:
            severity: warning
          annotations:
            summary: summary
            runbook_url: https://github.com/An619/Elastiflix/blob/main/docs/runbooks/elastiflix-availability.md
        - alert: ElastiflixBackendMetricsMissing
          expr: absent(up{service="backend"} == 1)
          labels:
            severity: warning
          annotations:
            summary: summary
"""

VALID_MONITOR = """\
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: test-monitor
  namespace: monitoring
  labels:
    release: monitoring
spec:
  selector:
    matchLabels:
      app: backend
  endpoints:
    - port: http
      path: /metrics
"""

VALID_APP = """\
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
spec:
  source:
    helm:
      values: |
        prometheus:
          prometheusSpec:
            ruleSelector:
              matchLabels:
                release: monitoring
            serviceMonitorSelector:
              matchLabels:
                release: monitoring
        grafana:
          sidecar:
            dashboards:
              label: grafana_dashboard
"""

VALID_DASHBOARD = """\
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  test.json: |-
    {
      "uid": "test",
      "title": "Test",
      "panels": [
        {"id": 1, "type": "timeseries", "title": "p", "targets": [{"expr": "elastiflix:test_ratio:rate5m"}]}
      ]
    }
"""


class ValidatorTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        (self.tmp / "kubernetes" / "monitoring").mkdir(parents=True)
        (self.tmp / "docs" / "runbooks").mkdir(parents=True)
        (self.tmp / "docs" / "runbooks" / "elastiflix-availability.md").write_text(
            "runbook\n", encoding="utf-8"
        )
        self.write("kubernetes/monitoring/rules.yaml", VALID_RULE)
        self.write("kubernetes/monitoring/monitor.yaml", VALID_MONITOR)
        self.write("kubernetes/monitoring/app.yaml", VALID_APP)
        self.write("kubernetes/monitoring/dashboard.yaml", VALID_DASHBOARD)

    def write(self, relative: str, content: str) -> None:
        (self.tmp / relative).write_text(content, encoding="utf-8")

    def run_validator(self) -> int:
        """Load the validator with ROOT pointed at the temporary tree."""
        spec = importlib.util.spec_from_file_location("validate_observability", VALIDATOR_PATH)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        module.ROOT = self.tmp
        module.KUBERNETES = self.tmp / "kubernetes"
        return module.main()

    def test_valid_tree_passes(self) -> None:
        self.assertEqual(self.run_validator(), 0)

    def test_invalid_promql_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/rules.yaml",
            VALID_RULE.replace(
                "expr: elastiflix:test_ratio:rate5m > 0.1",
                "expr: elastiflix:test_ratio:rate5m >",
                1,
            ),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("invalid PromQL", str(ctx.exception))

    def test_undefined_recording_rule_reference_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/dashboard.yaml",
            VALID_DASHBOARD.replace(
                "elastiflix:test_ratio:rate5m", "elastiflix:missing_rule:rate5m"
            ),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("undefined recording rule", str(ctx.exception))

    def test_missing_required_alert_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/rules.yaml",
            VALID_RULE.replace("alert: ElastiflixSLOFastBurn", "alert: SomethingElse"),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("missing expected alerts", str(ctx.exception))

    def test_service_monitor_without_release_label_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/monitor.yaml",
            VALID_MONITOR.replace("    release: monitoring\n", ""),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("release=monitoring", str(ctx.exception))

    def test_prometheus_selector_mismatch_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/app.yaml",
            VALID_APP.replace(
                "            ruleSelector:\n              matchLabels:\n                release: monitoring\n",
                "",
            ),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("ruleSelector", str(ctx.exception))

    def test_dangling_runbook_link_is_rejected(self) -> None:
        (self.tmp / "docs" / "runbooks" / "elastiflix-availability.md").unlink()
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("runbook that does not exist", str(ctx.exception))

    def test_rule_without_alert_or_record_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/rules.yaml",
            VALID_RULE.replace(
                "        - record: elastiflix:test_ratio:rate5m\n",
                "        - foo: elastiflix:test_ratio:rate5m\n",
            ),
        )
        with self.assertRaises(ValueError):
            self.run_validator()

    # --- Branches that a typo in a manifest would hit first. Each one is a
    # --- silent-failure mode in a live cluster, so each is pinned here.

    def test_service_monitor_without_endpoints_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/monitor.yaml",
            VALID_MONITOR.replace("  endpoints:\n    - port: http\n      path: /metrics\n", ""),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("no endpoints", str(ctx.exception))

    def test_service_monitor_endpoint_without_port_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/monitor.yaml",
            VALID_MONITOR.replace("    - port: http", "    - path: /metrics"),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("named port", str(ctx.exception))

    def test_grafana_sidecar_label_mismatch_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/app.yaml",
            VALID_APP.replace("label: grafana_dashboard", "label: grafana_dashboards"),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("sidecar label", str(ctx.exception))

    def test_prometheus_rule_needs_release_label(self) -> None:
        self.write(
            "kubernetes/monitoring/rules.yaml",
            VALID_RULE.replace("  labels:\n    release: monitoring\n", ""),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("PrometheusRule needs release=monitoring", str(ctx.exception))

    def test_prometheus_rule_without_groups_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/rules.yaml",
            "apiVersion: monitoring.coreos.com/v1\nkind: PrometheusRule\n"
            "metadata:\n  name: empty\n  labels:\n    release: monitoring\n"
            "spec:\n  groups: []\n",
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("no groups", str(ctx.exception))

    def test_rule_without_expr_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/rules.yaml",
            VALID_RULE.replace(
                "          expr: sum(rate(elastiflix_http_responses_total[5m]))\n",
                "          foo: bar\n",
                1,
            ),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("without expr", str(ctx.exception))

    def test_alert_without_summary_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/rules.yaml",
            VALID_RULE.replace(
                "          annotations:\n            summary: summary\n", "", 1
            ),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("summary annotation", str(ctx.exception))

    def test_alert_without_severity_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/rules.yaml",
            VALID_RULE.replace("          labels:\n            severity: critical\n", "", 1),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("severity label", str(ctx.exception))

    def test_alert_without_runbook_is_allowed(self) -> None:
        # A runbook link is optional; only a *broken* one is an error.
        self.write(
            "kubernetes/monitoring/rules.yaml",
            VALID_RULE.replace(
                "            runbook_url: https://github.com/An619/Elastiflix/blob/main/"
                "docs/runbooks/elastiflix-availability.md\n",
                "",
            ),
        )
        self.assertEqual(self.run_validator(), 0)

    def test_dashboard_without_uid_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/dashboard.yaml",
            VALID_DASHBOARD.replace('"uid": "test",\n      ', ""),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("needs a uid", str(ctx.exception))

    def test_dashboard_without_panels_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/dashboard.yaml",
            VALID_DASHBOARD.replace('"panels": [', '"nopanels": ['),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("invalid dashboard structure", str(ctx.exception))

    def test_missing_dashboard_is_rejected(self) -> None:
        (self.tmp / "kubernetes" / "monitoring" / "dashboard.yaml").unlink()
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("no Grafana dashboard", str(ctx.exception))

    def test_missing_service_monitor_is_rejected(self) -> None:
        (self.tmp / "kubernetes" / "monitoring" / "monitor.yaml").unlink()
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("no ServiceMonitor", str(ctx.exception))

    def test_missing_recording_rules_is_rejected(self) -> None:
        self.write(
            "kubernetes/monitoring/rules.yaml",
            VALID_RULE.replace(
                "        - record: elastiflix:test_ratio:rate5m\n"
                "          expr: sum(rate(elastiflix_http_responses_total[5m]))\n",
                "",
            ).replace(
                "elastiflix:test_ratio:rate5m > 0.1",
                "sum(rate(elastiflix_http_responses_total[5m])) > 0.1",
            ),
        )
        # The dashboard must not still reference the rule that was removed,
        # or the undefined-reference check (correctly) fires first.
        self.write(
            "kubernetes/monitoring/dashboard.yaml",
            VALID_DASHBOARD.replace(
                "elastiflix:test_ratio:rate5m",
                "sum(rate(elastiflix_http_responses_total[5m]))",
            ),
        )
        with self.assertRaises(ValueError) as ctx:
            self.run_validator()
        self.assertIn("no recording rules", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()


class CheckovGateTests(unittest.TestCase):
    """The Checkov report gate is the only enforcement of suppressions.

    Checkov's own exit code is not trustworthy (`--soft-fail` always succeeds),
    so this script decides whether CI passes. Its failure modes are tested
    against generated reports rather than by inspecting its source.
    """

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location(
            "check_checkov_report", ROOT / "scripts" / "check-checkov-report.py"
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cls.gate = module

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, payload, name="report.json"):
        path = self.tmp / name
        path.write_text(payload if isinstance(payload, str) else json.dumps(payload))
        return path

    def report(self, failed=(), skipped=()):
        return {
            "summary": {
                "passed": 10,
                "failed": len(failed),
                "skipped": len(skipped),
                "parsing_errors": 0,
            },
            "results": {"failed_checks": list(failed), "skipped_checks": list(skipped)},
        }

    def test_clean_report_passes(self):
        path = self.write(self.report())
        self.assertEqual(self.gate.main(["gate", str(path)]), 0)

    def test_unsuppressed_failure_fails(self):
        path = self.write(self.report(failed=[{"check_id": "CKV_K8S_1", "resource": "Pod.x"}]))
        self.assertEqual(self.gate.main(["gate", str(path)]), 1)

    def test_parse_errors_fail(self):
        payload = self.report()
        payload["summary"]["parsing_errors"] = 2
        self.assertEqual(self.gate.main(["gate", str(self.write(payload))]), 1)

    def test_suppression_with_reason_passes(self):
        skipped = [
            {
                "check_id": "CKV_K8S_15",
                "resource": "Deployment.x",
                "check_result": {"suppress_comment": "needs root, see ADR-0002"},
            }
        ]
        self.assertEqual(self.gate.main(["gate", str(self.write(self.report(skipped=skipped)))]), 0)

    def test_suppression_without_reason_fails(self):
        for comment in ("", "   ", None):
            with self.subTest(comment=comment):
                skipped = [
                    {
                        "check_id": "CKV_K8S_43",
                        "resource": "Deployment.y",
                        "check_result": {"suppress_comment": comment},
                    }
                ]
                path = self.write(self.report(skipped=skipped))
                self.assertEqual(self.gate.main(["gate", str(path)]), 1)

    def test_reason_at_top_level_is_accepted(self):
        skipped = [{"check_id": "CKV_K8S_15", "resource": "X", "suppress_comment": "reason"}]
        self.assertEqual(self.gate.main(["gate", str(self.write(self.report(skipped=skipped)))]), 0)

    def test_missing_file_is_rejected(self):
        with self.assertRaises(SystemExit):
            self.gate.main(["gate", str(self.tmp / "absent.json")])

    def test_non_json_suffix_is_rejected(self):
        path = self.write(self.report(), name="report.txt")
        with self.assertRaises(SystemExit):
            self.gate.main(["gate", str(path)])

    def test_invalid_json_is_rejected(self):
        path = self.write("{not json")
        with self.assertRaises(SystemExit):
            self.gate.main(["gate", str(path)])

    def test_symlink_is_rejected(self):
        target = self.write(self.report())
        link = self.tmp / "link.json"
        try:
            link.symlink_to(target)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks unavailable on this platform")
        with self.assertRaises(SystemExit):
            self.gate.main(["gate", str(link)])

    def test_wrong_argument_count_returns_usage_error(self):
        self.assertEqual(self.gate.main(["gate"]), 2)
