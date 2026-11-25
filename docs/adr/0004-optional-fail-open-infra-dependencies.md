# ADR 0004: Redis and RabbitMQ are optional, fail-open dependencies

- **Status:** Accepted
- **Date:** 2026-11-25
- **Deciders:** Project maintainer

## Context

The backend uses Redis (response cache, `SETEX search:<sha256>`, 300 s TTL, keyed on the full search-ui state + `queryConfig`) and RabbitMQ (`search_events`, 24 h TTL, 10k-message cap, `drop-head`). Search itself does not depend on either. Hard-failing requests because a cache or analytics queue is unhealthy would couple the critical path to optional infrastructure.

## Decision

Both integrations are **optional and fail open** (`backend/src/Backend.js`):

- If `REDIS_URL`/`REDIS_HOST` is unset → caching disabled, app runs (`redis_disabled` log line). If Redis errors at runtime → caught, logged (`cache_error`), request proceeds uncached.
- If `RABBITMQ_URL`/`RABBITMQ_HOST` is unset → events disabled (`rabbitmq_disabled`). Publish failures are caught and logged (`rabbitmq_publish_fail`); the response is never affected.
- Cache **hits** still emit the same structured log line as misses (`cache_hit: true`) so dashboards stay accurate.
- Connections at boot use bounded error handling with reconnect-safe event handlers; queues are asserted with TTL + max-length so an unconsumed queue cannot grow unboundedly.

## Consequences

- ✅ Cache/queue outage = degraded efficiency & analytics, never an outage of search.
- ✅ Local dev needs no services (`npm start` works); Docker Compose wires the full stack for realism.
- ✅ Observability degradation is visible in logs, not silent.
- ⚠️ A failing Redis increments no metric beyond `errors` — cache-hit rate is inferred from logs; Metrics endpoint exposes `elastiflix_cache_hits_total` for scraping.
- ⚠️ "Fail open" means a misconfigured Redis is *hidden* until you look at logs — mitigated by `redis_connect_fail`/`cache_error` events and the disabled-by-default behavior when unset.

## Alternatives considered

- **Hard dependency:** rejected — violates the principle that observability/cache infra must not be on the critical path.
- **Circuit breaker library:** overkill at this scale; bounded handlers + logs suffice and keep `npm ci` lean.
