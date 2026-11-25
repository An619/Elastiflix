# Elastiflix — Interview Demo Runbook (10–12 minutes)

Everything below matches the repo exactly. Practice it once end-to-end before the interview.

## 0. Prep (before the interview, 5 min)

```bash
git clone https://github.com/An619/Elastiflix.git && cd Elastiflix
./start.sh          # boots the whole ELK + app stack (first run: pulls images, ~3–5 min)
```

Have these tabs open and logged in:

| Tab | URL | Credentials |
|---|---|---|
| Elastiflix app | http://localhost:3000 | — |
| Kibana | http://localhost:5601 | none (demo mode) |
| RabbitMQ management | http://localhost:15672 | `user` / `elastiflix-rabbit-pass` |
| GitHub repo + Actions | https://github.com/An619/Elastiflix/actions | — |
| SonarCloud | https://sonarcloud.io/summary/new_code?id=An619_Elastiflix | — |

Sanity checks: `curl -s localhost:17700/healthz` → `OK` · `curl -s localhost:9200/_cluster/health?pretty` → status `yellow` (correct for single-node).

---

## 1. The app (2 min) — "what the product does"

1. Open the app → search **"heat"** → show instant results, facets (genres, year, rating), pagination.
2. Point at the network tab: requests go to `/api/search` — the browser never talks to Elasticsearch directly.
3. Type **"interstellar"** in the search box → show **autocomplete** (`/api/autocomplete`).
4. Toggle the search mode if visible (lexical ↔ semantic) — same index, different query strategy. One sentence: *"Lexical is BM25 keyword matching; semantic embeds the query (ELSER/E5) and retrieves nearest vectors; hybrid fuses both; rerank rescores the top hits."*

**Say:** "The UI is Elastic's react-search-ui — facets, sort, and paging are query-state, so every interaction is just a new search-ui state object."

## 2. The data path (1 min) — "how the catalog gets there"

- `data-loader/index-data.py` bulk-indexes `movies.json.gz` into `elastiflix-movies`.
- It stringifies `id` for the keyword mapping and **derives `user_score` from TMDB `vote_average`** (the UI facet was empty upstream until I fixed that).
- Index templates (`data-loader/config/*.json`, Logstash templates) mean mappings are never dynamically guessed.

## 3. Observability (2 min) — "how I would run this in production"

1. Kibana → **Movies** dashboard: distribution of ratings/genres.
2. Run `./generate-traffic.sh` in another shell → refresh Kibana → show logs flowing (Filebeat → Logstash → ES).
3. RabbitMQ tab → **queues** → `search_events` has depth/acks — "every successful search publishes an event; 24h TTL, 10k cap, drop-head."
4. Show `GET /metrics` → "hand-rolled Prometheus exposition — no dependency; in K8s the monitoring stack scrapes this."

**Say:** "In the cluster this is kube-prometheus-stack + Grafana for metrics and the same Filebeat/Logstash/Kibana pipeline for logs."

## 4. The delivery pipeline (2–3 min) — "what happens when I merge"

Open **GitHub Actions** and walk left → right:

1. `code-tests` — jest (frontend), `node --test` (backend, mocked Redis/RabbitMQ), `terraform validate`, kubeconform.
2. `secret-scanning` — Gitleaks.
3. `dependency-checks` — prod-only `npm audit --omit=dev --audit-level=high`, pip-audit.
4. `code-quality` — Hadolint on all four Dockerfiles.
5. `sonar-qube` — SonarCloud Quality Gate: **≥ 80% coverage on new code, 0 blocking issues** — demonstrate it by opening the PR quality gate (PR #1 history shows it going from 47.7% → 83.0% coverage and C → A security rating).
6. `docker-checks` — Trivy (CRITICAL/HIGH fails) + Checkov (Terraform hard gate; k8s report-only while manifest hardening is pending).
7. `docker-push` (main only) — builds both images, pushes `an619/elastiflix-*:<sha>`, commits the tag bump back to `main` with `[skip ci]`.

**Say:** "Every third-party action is pinned to a commit SHA — a compromised tag can't reach the pipeline."

## 5. GitOps & the cluster (2 min) — "how it actually gets to prod"

1. `kubernetes/application/frontend/deployment.yaml` → **Argo Rollouts canary**: 20% → 30s pause → 100%. "A bad frontend never sees more than 20% of users; rollback is `kubectl argo rollouts undo`."
2. `argocd-*.yaml` — **app-of-apps**: app, infra (Redis/RabbitMQ), ELK, ingress, monitoring. Argo CD watches HEAD of `main`, automated prune + self-heal.
3. Secrets: `kubernetes/infra/*-sealedsecret.yaml` — encrypted at rest in git; only the in-cluster sealed-secrets controller can open them. On EKS the backend secret comes from **AWS Secrets Manager via ESO + IRSA** — no static AWS keys anywhere.
4. Images run **non-root**, `drop: [ALL]`, `allowPrivilegeEscalation: false`.

## 6. Architecture walk-through (1–2 min)

Open `docs/adr/` first if asked *why* (GitOps over push, SHA-tagged images, frontend canary, fail-open infra) — then open `README.md` → the architecture SVG. Narrate: *"One repo, one flow — build left to right: Developer → GitHub Actions → Docker Hub → Argo CD → the cluster. Inside the cluster: Ingress → Frontend → Backend → Elasticsearch, with Redis caching and RabbitMQ events, and everything observed by the ELK/Prometheus stack."*

---

## Likely interview questions — crisp answers

**Why GitOps instead of `kubectl apply` from CI?**
Git is the only source of truth; the cluster pulls and self-heals. CI never needs cluster credentials — the attack surface of the pipeline drops to zero, and drift is impossible or auto-corrected. Rollback = revert a commit.

**Why tag images with the git SHA instead of `latest`?**
Immutability + provenance. `kubectl describe` tells you exactly which commit runs in prod; there's no ambiguity about what `latest` points to; rollbacks and audits are trivial.

**What happens if Redis or RabbitMQ is down?**
The backend degrades gracefully: cache reads/writes fail open (search still works, `cache_hit` just stops incrementing), and event publishing is wrapped in try/catch — the request never fails because observability infra is unhealthy.

**Why is the frontend a Rollout but the backend a plain Deployment?**
The frontend is the user-visible surface where canary analysis (errors/latency at 20% traffic) has the highest payoff and rollback is cheapest. The backend is idempotent and stateless; its rollout strategy is a deliberate trade-off (Blue/Green or analysis templates would be the next step).

**How does SonarCloud block a PR?**
Quality Gate on new code: 0 new issues/vulnerabilities, ≥ 80% coverage on new lines, 0% duplication. The check is a required status — PRs can't merge red.

**How are secrets handled end-to-end?**
Local: `.env` (gitignored). Compose/demo: inline demo values clearly marked as such. Kubernetes: Sealed Secrets (encrypted in git). AWS EKS: External Secrets Operator syncs Secrets Manager via IRSA — the cluster never stores a long-lived credential.

**Why is single-node Elasticsearch "yellow"?**
A single node can't allocate a replica on the same node, so the primary shard is active but unassigned replicas stay yellow forever. Green is expected only in multi-node clusters; healthchecks accept yellow on purpose.

**How would you roll back a bad deploy?**
Frontend: `kubectl argo rollouts undo rollout/frontend -n elastiflix` (or `abort`). Backend: `kubectl rollout undo deploy/backend -n elastiflix`. GitOps-wise: revert the commit that bumped the tag — Argo CD reconciles everything back automatically.

**Why is k8s Checkov report-only but Terraform hard-fail?**
Terraform findings were fixed and can be enforced at zero known-false-positive cost. The k8s manifests still carry ~105 accepted findings (digest pinning, seccomp, root beats images) that need a registry + cluster to remediate and verify — tracked as tech debt, not silently ignored.

**How would this scale?**
ES: dedicated master/data nodes, shard count tuned to the index budget. Backend: HPA on CPU + RPS (metrics already exposed). Frontend is static behind nginx — trivially horizontal. Redis: add a replica + Sentinel. RabbitMQ: quorum queues at higher throughput.

**What would you improve next?**
OPA/Gatekeeper policies in-cluster, digest-pinned base images, signed images (cosign) + admission verification, k6 load tests in CI, and promoting the frontend Rollout to analysis-based canary (metric-driven abort).

## Exit one-liner

*"This repo is how I build things: boring, reproducible, self-healing — and every claim in it is enforced by a gate I can show you failing."*
