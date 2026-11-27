# Runbook: Elastiflix availability alerts

Applies to `ElastiflixSLOFastBurn`, `ElastiflixSLOSlowBurn`,
`ElastiflixSLOObjectiveMiss`, `ElastiflixBackendMetricsMissing`,
`ElastiflixRedisUnavailable` and `ElastiflixBackendHighLatency`
(defined in `kubernetes/monitoring/observability.yaml`).

## Read this first

**Alerts do not notify anyone yet.** `alertmanager.enabled` is `false` in
`kubernetes/argocd-monitoring.yaml` because there is no approved destination,
owner, or escalation policy. Until that exists these alerts are visible only on
the Prometheus **Alerts** page and the Grafana **Elastiflix SLO and Error
Budget** dashboard. Treat "no notification" as "nobody was paged", not as
"nothing happened".

## Step 1 — establish whether the signal is real

1. Open Prometheus → Status → Targets and confirm the `elastiflix/backend`
   target is `UP`.
   - **Target missing or down** → the SLI is *unknown*, not healthy. Stop
     treating the SLO panels as evidence and go to step 2.
   - **Target up** → continue.
2. Check `elastiflix:slo_requests:increase7d`. Under ~100 requests the ratio is
   dominated by single requests; a "1 % error rate" may be one 500.
3. Confirm the window is populated. A freshly deployed cluster has less than
   seven days of data, and Prometheus `retention` is 7 days, so a full window
   only exists after a week of continuous uptime.

## Step 2 — the target is not being scraped

1. `kubectl -n elastiflix get endpoints backend` — no endpoints means the
   Service selector and pod labels disagree, or no pod is Ready.
2. `kubectl -n elastiflix get servicemonitor elastiflix-backend -o yaml` — the
   `release: monitoring` label must match
   `prometheus.prometheusSpec.serviceMonitorSelector`.
3. `kubectl -n elastiflix get networkpolicy` — if NetworkPolicy is enforced,
   the `backend-ingress` rule must allow the `monitoring` namespace on 17700.
   A missing rule looks exactly like a broken application.
4. `kubectl -n elastiflix port-forward deploy/backend 17700` then
   `curl -s localhost:17700/metrics | head` — proves the endpoint itself works.

## Step 3 — triage the error signal

1. Compare `elastiflix:error_ratio:rate5m` with `rate1h`. A 5m spike that the 1h
   window does not share is usually a single bad request or a restart.
2. Identify the route with
   `sum by (route, status_class) (rate(elastiflix_http_responses_total[5m]))`.
   `/api/*` failing points at Elasticsearch; `/other` failing is usually a
   client asking for a path that does not exist (which returns 404, not 5xx).
3. Check the backend logs for `search_failed`, `autocomplete_failed`,
   `redis_error`, `rabbitmq_fail`. **Never paste query text, credentials, or
   other customer-visible data into a ticket or chat.**
4. Check dependencies in this order: Elasticsearch
   (`kubectl -n elastic-stack get pods`), then Redis and RabbitMQ
   (`kubectl -n infra get pods`). Redis and RabbitMQ are optional by design
   (ADR-0004): their failure degrades caching and analytics but must not produce
   5xx for search. If it does, that is the defect.
5. Correlate with changes: `kubectl -n elastiflix get rollout frontend -o
   yaml` (`status.currentPodHash`), `kubectl argo rollouts get rollout frontend
   -n elastiflix --watch`, and recent Argo CD sync history.

## Step 4 — mitigate

- **Bad canary in flight:** `kubectl argo rollouts abort frontend -n elastiflix`.
  This returns traffic to the stable ReplicaSet and scales down the canary.
  Verify with `kubectl argo rollouts get rollout frontend -n elastiflix`.
- **Bad image already promoted:** revert the image reference in Git and let Argo
  CD sync (`git revert`, then watch the Application). Do not `kubectl set image`
  — selfHeal will undo it and the cluster will drift from Git.
- **Dependency outage:** coordinate with the owner; do not delete the
  PrometheusRule or raise thresholds to make the alert stop.
- **Latency only (no errors):** check Elasticsearch heap and query throughput
  first; `elastiflix_http_request_duration_seconds` is measured in the backend,
  so it includes all time spent waiting on Elasticsearch.

## Step 5 — close out

1. Confirm `elastiflix:error_ratio:rate5m` and `rate1h` are below the burn
   thresholds and the target is `UP`.
2. Record: alert name, start/end in UTC, user-visible impact, the change or
   dependency responsible, and the error budget consumed
   (`1 - elastiflix:slo_error_budget_remaining:ratio7d`).
3. If this is the second occurrence of the same cause, add a regression test or
   alert rather than relying on this runbook.

## Known limitations of this SLO

- 99.5 % over 7 days is a **proposal for a demo deployment**, not an approved
  SLA, and it has never been measured.
- 4xx responses count as successes for this objective. A regression that turns
  valid requests into 400s would not burn budget.
- `/healthz` is excluded; Prometheus' `/metrics` scrapes are excluded in the
  application before counting.
- The frontend's availability is measured through the backend only. A frontend
  that serves a broken bundle while the API stays healthy is invisible here.
