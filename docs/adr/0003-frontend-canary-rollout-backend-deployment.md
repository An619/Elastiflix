# ADR 0003: Frontend on Argo Rollouts canary; backend on a plain Deployment

- **Status:** Accepted
- **Date:** 2026-11-25
- **Deciders:** Project maintainer

## Context

Both tiers are stateless and 2-replica, but their blast radii and verification signals differ. The frontend is what users see and where visual/JS regressions appear; the backend is a JSON API whose contract is guarded by CI tests and SonarCloud.

## Decision

- **Frontend** (`kubernetes/application/frontend/deployment.yaml`): `kind: Rollout` (Argo Rollouts) with a canary strategy — `setWeight: 20` → `pause: 30s` → `setWeight: 100`. Rollouts can be aborted/aborted-back with `kubectl argo rollouts abort|undo`.
- **Backend**: standard `apps/v1 Deployment` with readiness/liveness probes on `/healthz` and 2 replicas; rolling update is sufficient given API-side safety nets (CI tests, contract shape, error taxonomy `search_failed`/`autocomplete_failed`).

## Consequences

- ✅ The most user-visible tier ships gradually; a broken build exposes ≤20% of sessions for 30 seconds.
- ✅ Rollback is one command, no rebuild.
- ⚠️ Two deployment kinds to understand; runbooks must mention both paths.
- ⚠️ Backend canary remains a documented trade-off; next step is analysis-driven canary (Prometheus-metric abort) for the backend too.

## Alternatives considered

- **Both on Rollouts:** more uniform, but doubles operator surface without changing backend risk.
- **Both plain Deployments:** simplest, loses the frontend safety net that justifies the platform's progressive-delivery story.
