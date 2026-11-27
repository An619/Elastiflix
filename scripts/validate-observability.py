#!/usr/bin/env python3
"""Validate Prometheus rules and Grafana dashboards without a cluster.

The rules and dashboards in kubernetes/monitoring/ are only exercised at runtime,
so a typo in a PromQL expression or a dashboard whose panels query a series that
does not exist would be discovered by whoever is on call. This checks, offline:

* every PrometheusRule and dashboard JSON parses;
* every PromQL expression parses (promql-parser);
* each rule declares exactly one of alert/record and has an expr;
* the SLO alerts and their runbook links exist;
* every recording rule referenced by an alert or dashboard is defined;
* dashboards are structurally valid and their panel queries parse.

Exit code 0 only when every check passes.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
KUBERNETES = ROOT / "kubernetes"

REQUIRED_ALERTS = {
    "ElastiflixSLOFastBurn",
    "ElastiflixSLOSlowBurn",
    "ElastiflixSLOObjectiveMiss",
    "ElastiflixBackendMetricsMissing",
}

# Recording rules are referenced as `elastiflix:name:window`; this pattern
# distinguishes them from metric names, which never contain a colon.
RECORDING_RULE_REF = re.compile(r"\belastiflix:[a-zA-Z0-9_]+:[a-zA-Z0-9]+\b")


def documents(path: Path):
    with path.open(encoding="utf-8") as stream:
        for document in yaml.safe_load_all(stream):
            if isinstance(document, list):
                yield from (item for item in document if item is not None)
            elif document is not None:
                yield document


def validate_promql(expression: str, origin: str) -> None:
    """Parse PromQL; raise ValueError with context on failure."""
    try:
        from promql_parser import parse
    except ImportError:  # pragma: no cover - dependency is installed in CI
        raise SystemExit(
            "promql-parser is not installed; run: pip install promql-parser"
        )

    try:
        parse(expression)
    except Exception as error:  # parser errors carry the offending position
        raise ValueError(f"invalid PromQL in {origin}: {error}") from error


def main() -> int:
    files = sorted(KUBERNETES.rglob("*.yaml"))
    rules = 0
    alerts: dict[str, dict] = {}
    recording_rules: set[str] = set()
    expressions: list[tuple[str, str]] = []
    dashboards = 0
    dashboard_queries = 0
    service_monitors = 0

    for path in files:
        for resource in documents(path):
            if not isinstance(resource, dict):
                continue
            kind = resource.get("kind")
            origin = path.relative_to(ROOT)

            if kind == "ServiceMonitor":
                labels = (resource.get("metadata") or {}).get("labels") or {}
                if labels.get("release") != "monitoring":
                    raise ValueError(
                        f"{origin}: ServiceMonitor needs release=monitoring or "
                        "Prometheus will not select it"
                    )
                endpoints = resource.get("spec", {}).get("endpoints") or []
                if not endpoints:
                    raise ValueError(f"{origin}: ServiceMonitor has no endpoints")
                for endpoint in endpoints:
                    if not endpoint.get("port"):
                        raise ValueError(
                            f"{origin}: ServiceMonitor endpoint needs a named port"
                        )
                service_monitors += 1

            elif kind == "Application" and (resource.get("metadata") or {}).get("name") == "monitoring":
                raw_values = (
                    resource.get("spec", {}).get("source", {}).get("helm", {}).get("values")
                )
                values = yaml.safe_load(raw_values or "{}")
                prometheus_spec = values.get("prometheus", {}).get("prometheusSpec", {})
                for selector_name in ("ruleSelector", "serviceMonitorSelector"):
                    selector = prometheus_spec.get(selector_name, {}).get("matchLabels", {})
                    if selector.get("release") != "monitoring":
                        raise ValueError(
                            f"{origin}: {selector_name} must select release=monitoring "
                            "or the rules/ServiceMonitors are created and never used"
                        )
                dashboards_sidecar = (
                    values.get("grafana", {}).get("sidecar", {}).get("dashboards", {})
                )
                if dashboards_sidecar.get("label") != "grafana_dashboard":
                    raise ValueError(
                        f"{origin}: Grafana dashboard sidecar label does not match the "
                        "grafana_dashboard ConfigMap labels"
                    )

            elif kind == "PrometheusRule":
                labels = (resource.get("metadata") or {}).get("labels") or {}
                if labels.get("release") != "monitoring":
                    raise ValueError(
                        f"{origin}: PrometheusRule needs release=monitoring"
                    )
                groups = resource.get("spec", {}).get("groups") or []
                if not groups:
                    raise ValueError(f"{origin}: PrometheusRule has no groups")
                for group in groups:
                    if not group.get("name") or not group.get("rules"):
                        raise ValueError(
                            f"{origin}: group {group.get('name')!r} needs a name and rules"
                        )
                    for rule in group["rules"]:
                        has_alert = bool(rule.get("alert"))
                        has_record = bool(rule.get("record"))
                        if has_alert == has_record:
                            raise ValueError(
                                f"{origin}: each rule must declare exactly one of "
                                "alert or record"
                            )
                        expression = rule.get("expr")
                        if not expression:
                            raise ValueError(f"{origin}: rule without expr")
                        name = rule.get("alert") or rule.get("record")
                        validate_promql(expression, f"{origin}:{name}")
                        expressions.append((f"{origin}:{name}", expression))
                        if has_alert:
                            annotations = rule.get("annotations", {})
                            if not annotations.get("summary"):
                                raise ValueError(
                                    f"{origin}:{name}: alert needs a summary annotation"
                                )
                            if not rule.get("labels", {}).get("severity"):
                                raise ValueError(
                                    f"{origin}:{name}: alert needs a severity label"
                                )
                            alerts[rule["alert"]] = annotations
                        else:
                            recording_rules.add(rule["record"])
                        rules += 1

            elif kind == "ConfigMap" and (
                ((resource.get("metadata") or {}).get("labels") or {}).get("grafana_dashboard")
                == "1"
            ):
                for filename, raw_json in (resource.get("data") or {}).items():
                    if not filename.endswith(".json"):
                        continue
                    dashboard = json.loads(raw_json)
                    if not dashboard.get("title") or not isinstance(
                        dashboard.get("panels"), list
                    ):
                        raise ValueError(f"{origin}:{filename}: invalid dashboard structure")
                    if not dashboard.get("uid"):
                        raise ValueError(f"{origin}:{filename}: dashboard needs a uid")
                    for panel in dashboard["panels"]:
                        for target in panel.get("targets", []):
                            if target.get("expr"):
                                panel_origin = (
                                    f"{origin}:{filename}:{panel.get('title', 'panel')}"
                                )
                                validate_promql(target["expr"], panel_origin)
                                expressions.append((panel_origin, target["expr"]))
                                dashboard_queries += 1
                    dashboards += 1

    missing = REQUIRED_ALERTS - set(alerts)
    if missing:
        raise ValueError(f"missing expected alerts: {', '.join(sorted(missing))}")

    for name, annotations in alerts.items():
        runbook = annotations.get("runbook_url")
        if runbook:
            runbook_path = ROOT / runbook.split("/blob/main/")[-1]
            if not runbook_path.is_file():
                raise ValueError(
                    f"alert {name} links to a runbook that does not exist: {runbook_path}"
                )

    # Every recording rule a rule or dashboard refers to must be defined, or the
    # panel/alert silently evaluates to nothing.
    undefined: set[str] = set()
    for origin, expression in expressions:
        undefined |= set(RECORDING_RULE_REF.findall(expression)) - recording_rules
    if undefined:
        raise ValueError(
            "references undefined recording rule(s): " + ", ".join(sorted(undefined))
        )

    if service_monitors < 1:
        raise ValueError("no ServiceMonitor found")
    if dashboards < 1:
        raise ValueError("no Grafana dashboard found")
    if not recording_rules:
        raise ValueError("no recording rules found")

    print(
        f"Validated {len(files)} Kubernetes YAML files: {rules} Prometheus rules "
        f"({len(alerts)} alerts, {len(recording_rules)} recording rules), "
        f"{service_monitors} ServiceMonitor(s), {dashboards} dashboard(s) with "
        f"{dashboard_queries} PromQL panel queries."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # noqa: BLE001 - surface a single actionable message
        print(f"Observability validation failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
