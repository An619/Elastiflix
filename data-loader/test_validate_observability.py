"""Tests for scripts/validate-observability.py.

The validator is the only thing standing between a typo in a PromQL expression
and a dashboard that silently shows nothing, so its failure modes are tested
against temporary copies of the tree rather than the real manifests.
"""
from __future__ import annotations

import importlib.util
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


if __name__ == "__main__":
    unittest.main()
