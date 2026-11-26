# Phase 5: SRE observability and service-level objectives

## Scope and status

This phase adds repository-managed request SLIs, a proposed availability objective, burn-rate rules, a Grafana SLO dashboard, and an operator runbook. No cluster was queried, no Prometheus rule was evaluated, and no Alertmanager notification or dashboard was runtime-tested.

The 99.5% rolling seven-day availability objective is a **proposed engineering target**, not a customer SLA. Product/service owners should approve or change the target before it is used for external commitments. Rules evaluate in Prometheus, but Alertmanager remains disabled until an approved notification receiver and escalation policy exist.

## Signals and objective

The backend now exports:

- `elastiflix_http_responses_total{route,status_class}`: completed responses grouped by a bounded route allowlist and HTTP status class. Unknown URLs collapse to `/other` or `/api/other`; query strings, IDs, search text, and other user values are never labels.
- `elastiflix_http_request_duration_seconds`: a response-latency histogram with fixed buckets for each bounded route.
- `elastiflix_errors_total`: increments for every completed HTTP 5xx response, not only autocomplete failures. Prometheus `/metrics` scrapes are excluded from application counters and latency statistics.

The proposed availability SLI is successful non-health-check HTTP responses divided by all non-health-check HTTP responses over a rolling seven days. Only 5xx responses count as bad events; 4xx responses do not. `/healthz` is excluded, and `/metrics` is not instrumented. The corresponding SLO is 99.5% availability, leaving a 0.5% error budget. The SLO-miss alert requires at least 100 requests in the window; during the first week, the rolling window is still filling and must not be represented as a mature seven-day report.

The selected seven-day query window fits the pinned kube-prometheus-stack 58.2.2 default Prometheus retention of 10 days. Do not reduce retention below seven days without changing the SLO query and dashboard. This repository does not set storage capacity; confirm the existing PVC/storage policy and retention on the target cluster before relying on long-window data.

## Alerts and dashboards

`kubernetes/monitoring/slo-rules.yaml` adds recording rules plus:

- Fast burn: 5-minute and 1-hour error ratios both exceed 7.2% (14.4× the 0.5% budget burn rate), sustained for two minutes.
- Slow burn: 30-minute and 6-hour error ratios both exceed 3% (6× burn rate), sustained for fifteen minutes.
- Objective miss: rolling seven-day availability below 99.5%, with at least 100 requests.

The `Elastiflix SLO and Error Budget` dashboard shows rolling availability, estimated error-budget remaining, request rate, server-error ratio, and p95 latency. A zero-traffic window is not treated as positive evidence of availability; check the scrape-target alert and traffic before interpreting the SLO panels.

These rules are discovered by the existing PrometheusRule selector (`release: monitoring`) and dashboards by the Grafana sidecar label (`grafana_dashboard: "1"`). Alertmanager is deliberately disabled, so the alerts are visible/evaluable in Prometheus but **do not page or notify anyone**.

## Validation performed in the workspace

- Backend tests cover response/error accounting, bounded low-cardinality route labels, histogram exposition, and exclusion of private paths/query values (42 backend tests passed).
- `scripts/validate-observability.py` parsed 54 Kubernetes YAML files, all 18 Prometheus rule expressions, and all three Grafana dashboards (including dashboard PromQL). The generated backend exposition parsed with the Prometheus Python client.
- PrometheusRule selector labels and Grafana sidecar labels were checked against the configured chart values. No live Prometheus, Grafana, Alertmanager, or deployed application endpoint was queried. Runtime scrape discovery, rule evaluation, retention, dashboard rendering, and notification delivery remain operator validation items.

## Operator acceptance checklist

1. Confirm the `elastiflix-backend` ServiceMonitor target is healthy and that response counters increment for representative 2xx, 4xx, and 5xx responses. Confirm `/metrics` scrapes do not change application counters.
2. Confirm Prometheus has at least seven days of retained data before using the rolling objective as a mature SLO report. Verify the actual retention and PVC capacity; the chart defaults are not proof of cluster settings.
3. Check the three SLO alerts and recording rules in Prometheus. Use controlled, non-production traffic to verify the error-ratio and burn-rate expressions; do not deliberately inject errors into production.
4. Confirm the dashboard is loaded, its Prometheus datasource UID resolves, and the latency histogram has samples. Treat p95 as unavailable until enough traffic exists.
5. Approve an Alertmanager receiver, routing tree, ownership, and escalation policy before enabling notifications. Test delivery to a non-production receiver before on-call use.
6. During an incident, follow [`../runbooks/elastiflix-availability.md`](../runbooks/elastiflix-availability.md). Validate stable/canary traffic separately; the current backend metrics are service-wide and do not identify frontend releases.

## Remaining caveats

- The 99.5% target is provisional and requires service-owner approval.
- Server-side instrumentation does not capture requests that fail before reaching the backend process, client-visible frontend failures, or latency outside the backend process.
- 4xx responses are excluded from the availability error numerator; adjust if the product considers specific 4xx statuses service failures.
- Metrics are process-local counters/histograms. Prometheus sums across backend replicas, but counter resets during pod replacement can affect short ranges until scrape data re-stabilizes.
- Existing aggregate metrics cannot attribute bad responses to a specific canary release. Do not interpret this as a canary-specific SLO.
- Alertmanager and external notification delivery remain off pending an approved receiver.
