# Elastiflix availability and SLO runbook

## Trigger

Use this runbook for `ElastiflixSLOFastBurn`, `ElastiflixSLOSlowBurn`, or `ElastiflixSLOObjectiveMiss`. Prometheus alerts are not notifications while Alertmanager is disabled; check the Prometheus Rules/Alerts page or the Grafana **Elastiflix SLO and Error Budget** dashboard.

## Triage

1. Confirm Prometheus scrape health for the backend ServiceMonitor. If targets are missing, treat the SLI as unknown rather than healthy; check the backend Service endpoints, namespace/selector labels, network policy, and Prometheus target discovery.
2. Check recent request rate, 5xx ratio by window, rolling seven-day availability, error-budget estimate, and p95 response latency. The proposed objective is 99.5% over seven days and is not an approved external SLA.
3. Inspect backend structured logs for status 500 and `search_failed` / `autocomplete_failed` events. Do not copy request query values, credentials, or other sensitive log data into tickets or chat.
4. Check Elasticsearch reachability/health, then Redis and RabbitMQ metrics if their behavior could explain the incident. These are dependencies; do not restart or mutate them without the normal incident/change process.
5. Review recent application image and GitOps changes. During a canary, compare live traffic routing and stable/canary health using the approved Argo Rollouts procedure; the existing request metrics are aggregate and cannot identify which release produced errors.

## Mitigation and recovery

- Follow the on-call/change process and use a reviewed rollback or Argo Rollouts abort only when the active rollout is confirmed to be the cause. Verify traffic has returned to the stable service and the stable pods remain ready.
- If the issue is a dependency outage, coordinate with its service owner; do not hide the signal by weakening alert thresholds or deleting the PrometheusRule.
- After recovery, confirm the request error ratio is below the burn thresholds, scrape targets are healthy, and no further 5xx increase is observed. Record the incident interval, user impact, contributing change/dependency, and remaining budget.

## SLO interpretation and escalation

- The rolling seven-day denominator excludes `/healthz`; Prometheus `/metrics` requests are not instrumented. 5xx responses are bad events; 4xx are currently counted as successful for this objective.
- The objective-miss alert waits for at least 100 requests. During the first seven days after data loss/redeployment, the window is not fully populated. Verify actual Prometheus retention and storage before relying on the dashboard.
- A flat/empty graph is not evidence of success. Check target health and request volume.
- Alertmanager is disabled pending an approved destination, owner, and escalation policy. Until those are approved and tested, monitoring alerts do not page anyone; follow the established human incident channel.
