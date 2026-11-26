#!/usr/bin/env python3
"""Validate Prometheus rule/dashboard PromQL and Grafana dashboard JSON."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml
from promql_parser import parse

ROOT = Path(__file__).resolve().parents[1]
KUBERNETES = ROOT / "kubernetes"
EXPECTED_SLO_ALERTS = {
    "ElastiflixSLOFastBurn",
    "ElastiflixSLOSlowBurn",
    "ElastiflixSLOObjectiveMiss",
}


def documents(path: Path):
    with path.open(encoding="utf-8") as stream:
        for document in yaml.safe_load_all(stream):
            if isinstance(document, list):
                yield from (item for item in document if item is not None)
            elif document is not None:
                yield document


def validate_promql(expression: str, origin: str) -> None:
    try:
        parse(expression)
    except Exception as error:  # parser errors include the offending expression position
        raise ValueError(f"Invalid PromQL in {origin}: {error}") from error


def main() -> int:
    files = sorted(KUBERNETES.rglob("*.yaml"))
    rule_count = 0
    dashboard_count = 0
    monitoring_app_count = 0
    service_monitor_count = 0
    found_alerts: set[str] = set()

    for path in files:
        for resource in documents(path):
            if not isinstance(resource, dict):
                continue
            kind = resource.get("kind")
            if kind == "ServiceMonitor":
                labels = resource.get("metadata", {}).get("labels", {})
                if labels.get("release") != "monitoring":
                    raise ValueError(f"{path}: ServiceMonitor lacks release=monitoring selector label")
                service_monitor_count += 1

            if kind == "Application" and resource.get("metadata", {}).get("name") == "monitoring":
                raw_values = resource.get("spec", {}).get("source", {}).get("helm", {}).get("values")
                values = yaml.safe_load(raw_values or "{}")
                prom_spec = values.get("prometheus", {}).get("prometheusSpec", {})
                for selector_name in ("ruleSelector", "serviceMonitorSelector"):
                    selector = prom_spec.get(selector_name, {}).get("matchLabels", {})
                    if selector.get("release") != "monitoring":
                        raise ValueError(f"{path}: {selector_name} must select release=monitoring")
                dashboards = values.get("grafana", {}).get("sidecar", {}).get("dashboards", {})
                if dashboards.get("label") != "grafana_dashboard" or str(dashboards.get("labelValue")) != "1":
                    raise ValueError(f"{path}: Grafana sidecar dashboard selector does not match ConfigMap labels")
                monitoring_app_count += 1

            if kind == "PrometheusRule":
                labels = resource.get("metadata", {}).get("labels", {})
                if labels.get("release") != "monitoring":
                    raise ValueError(f"{path}: PrometheusRule lacks release=monitoring selector label")
                for group in resource.get("spec", {}).get("groups", []):
                    if not group.get("name") or not group.get("rules"):
                        raise ValueError(f"{path}: PrometheusRule group needs a name and rules")
                    for rule in group["rules"]:
                        has_alert = bool(rule.get("alert"))
                        has_record = bool(rule.get("record"))
                        if has_alert == has_record:
                            raise ValueError(f"{path}: each rule must declare exactly one of alert or record")
                        if "expr" not in rule:
                            raise ValueError(f"{path}: Prometheus rule has no expr")
                        validate_promql(rule["expr"], f"{path}:{rule.get('alert') or rule.get('record')}")
                        if has_alert:
                            found_alerts.add(rule["alert"])
                        rule_count += 1

            if kind == "ConfigMap" and resource.get("metadata", {}).get("labels", {}).get("grafana_dashboard") == "1":
                for filename, raw_json in resource.get("data", {}).items():
                    if not filename.endswith(".json"):
                        continue
                    dashboard = json.loads(raw_json)
                    if not dashboard.get("title") or not isinstance(dashboard.get("panels"), list):
                        raise ValueError(f"{path}:{filename}: invalid Grafana dashboard structure")
                    for panel in dashboard["panels"]:
                        for target in panel.get("targets", []):
                            if target.get("expr"):
                                validate_promql(target["expr"], f"{path}:{filename}:{panel.get('title', 'panel')}")
                    dashboard_count += 1

    missing = EXPECTED_SLO_ALERTS - found_alerts
    if missing:
        raise ValueError(f"Missing expected SLO alerts: {', '.join(sorted(missing))}")
    if monitoring_app_count < 2:
        raise ValueError("Expected local and EKS monitoring Applications with matching selectors")
    if service_monitor_count < 1:
        raise ValueError("No ServiceMonitor resources were found")
    print(f"Validated {len(files)} Kubernetes YAML files, {rule_count} Prometheus rules, {service_monitor_count} ServiceMonitors, {dashboard_count} Grafana dashboards, and {monitoring_app_count} monitoring Applications.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Observability validation failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
