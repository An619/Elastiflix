# Phase 5 — SRE observability

## Status on current `main` before this branch

`kube-prometheus-stack 58.2.2` was deployed through Argo CD with
`alertmanager.enabled: false`. Nothing else existed:

- **No ServiceMonitor.** Prometheus had no application target at all.
- **No PrometheusRule.** No recording rules, no alerts, no SLO.
- **No dashboard.**
- The backend `/metrics` exported four process-wide counters with no labels:
  no status class, no route and no latency histogram. Scrapes of `/metrics`
  incremented the request counter itself, so monitoring traffic would inflate
  the very signal an SLO is computed from, and `elastiflix_errors_total`
  counted autocomplete failures only.

So "we have observability" meant "a Prometheus pod is running".

## Application metrics (this branch)

`backend/src/Backend.js` now exports:

| Series | Type | Labels |
|---|---|---|
| `elastiflix_http_responses_total` | counter | `route`, `status_class` |
| `elastiflix_http_request_duration_seconds` | histogram | `route` (11 buckets to 10s) |
| `elastiflix_http_requests_total` | counter | none (kept for compatibility) |
| `elastiflix_search_requests_total` | counter | none |
| `elastiflix_cache_hits_total` | counter | none |
| `elastiflix_errors_total` | counter | none — every completed 5xx, counted once |
| `elastiflix_redis_up` | gauge | none — probed at scrape time, fails open to 0 |

**Cardinality is bounded by construction.** `route` comes from a fixed
allowlist (`/`, `/healthz`, the four search endpoints, `/api/autocomplete`);
anything else becomes `/api/other` or `/other`. Paths, IDs and query strings can
never become label values — there is a test asserting that a request to
`/api/users/private-id?query=private-query` leaves no trace in the exposition.

`/metrics` scrapes are excluded from the request counters, so monitoring traffic
cannot feed back into the SLO, and `/healthz` is excluded at query time in the
recording rules so kubelet probes do not dominate availability.

## Rules and alerts

10 recording rules and 6 alerts in `kubernetes/monitoring/observability.yaml`:

| Alert | Condition | Severity |
|---|---|---|
| `ElastiflixSLOFastBurn` | 5m and 1h 5xx ratio > 7.2% (14.4x burn) for 2m | critical |
| `ElastiflixSLOSlowBurn` | 30m and 6h ratio > 3% (6x burn) for 15m | warning |
| `ElastiflixSLOObjectiveMiss` | 7d availability < 99.5% with >100 requests | warning |
| `ElastiflixBackendMetricsMissing` | no healthy backend target for 5m | warning |
| `ElastiflixRedisUnavailable` | `elastiflix_redis_up == 0` for 10m | warning |
| `ElastiflixBackendHighLatency` | p95 `/api/*` latency > 1s for 10m | warning |

The missing-metrics alert exists specifically so a scrape failure is never read
as a healthy service, and the runbook says the same thing.

## SLO assumptions (explicit, not an SLA)

- Objective: **99.5% availability over a rolling 7 days** (0.5% error budget).
- Good = any non-5xx response on a non-`/healthz` route. **4xx counts as
  success**, so a regression that turns valid requests into 400s does not burn
  budget.
- The window is only meaningful after 7 days of continuous data; Prometheus
  retention is set to 7d, so a full window is a best case, not a guarantee.
- The frontend is measured only through the backend. A frontend serving a broken
  bundle while the API is healthy is invisible to this SLO.
- The objective has never been measured. It is a proposal for a demo deployment.

## Alert delivery prerequisites (NOT met)

`alertmanager.enabled` stays `false`. There is no approved destination, owner,
escalation policy or on-call rotation. Enabling Alertmanager without those would
look like paging coverage while notifying nobody — the runbook opens by saying
alerts currently notify no one and must be watched in Prometheus/Grafana.

To make delivery real: choose a receiver (email/Slack/PagerDuty), create the
credential Secret outside Git, set `alertmanager.enabled: true` plus a
`config.receivers`/`route` in `kubernetes/argocd-monitoring.yaml`, then send a
test alert and confirm it arrives. That is an operator decision with an owner —
not a code change this branch can make for you.

## Verification performed

- `scripts/validate-observability.py`: 37 Kubernetes YAML files, 16 rules
  (6 alerts, 10 recording rules), 1 ServiceMonitor, 1 dashboard, 9 panel queries
  — all parse, selectors match, required alerts present, every
  `elastiflix:*` recording-rule reference defined, every `runbook_url` resolves
  to a file in the repo.
- `data-loader/test_validate_observability.py`: 8 tests, including negative
  cases for invalid PromQL, an undefined recording rule, a missing required
  alert, a ServiceMonitor without `release=monitoring`, a `ruleSelector`
  mismatch, a dangling runbook link, and a rule with neither alert nor record.
- Backend: 38 tests pass, including the new metric surface tests.
- Both are wired into `code-tests.yml`.

## Not verified (needs a cluster)

- That Prometheus scrapes the backend and the series actually appear.
- That any rule evaluates, fires, or resolves (needs real traffic and a
  seven-day window).
- That the dashboard loads and its panels render (needs Grafana + datasource uid
  `prometheus`, which the chart provides).
- That the `monitoring` → `elastiflix` NetworkPolicy path allows scraping.

Safe operator checks:

```bash
kubectl -n elastiflix get servicemonitor elastiflix-backend -o yaml
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090
# then: Status → Targets; query elastiflix_http_responses_total
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
```

A flat or empty graph is **not** evidence of health — check the target first.
