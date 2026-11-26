# 🎬 Elastiflix — Enterprise DevSecOps & GitOps Movie Search

[![DevSecOps CI](https://github.com/An619/Elastiflix/actions/workflows/devsecops.yml/badge.svg?branch=main)](https://github.com/An619/Elastiflix/actions/workflows/devsecops.yml)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=An619_Elastiflix&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=An619_Elastiflix)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

![Elasticsearch](https://img.shields.io/badge/Elasticsearch_9.1-00BFB3?style=for-the-badge&logo=elasticsearch&logoColor=white)
![React](https://img.shields.io/badge/React_18-20232A?style=for-the-badge&logo=react&logoColor=61DAFB)
![Node.js](https://img.shields.io/badge/Node.js_22-339933?style=for-the-badge&logo=node.js&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)
![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=for-the-badge&logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS_EKS-232F3E?style=for-the-badge&logo=amazon-aws&logoColor=white)
![Argo CD](https://img.shields.io/badge/Argo_CD-EF7B4D?style=for-the-badge&logo=argo&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/GitHub_Actions_CI/CD-2088FF?style=for-the-badge&logo=github-actions&logoColor=white)

Elastiflix is a **3-tier movie-search reference application** (React · Node.js · Elasticsearch) with DevSecOps and GitOps components. The repository includes local Docker Compose and Minikube paths, plus AWS/EKS scaffolding that still requires validation before it should be described as production-ready. Observability and secrets-management components are present; backup/restore automation is not yet wired end to end.

> **Live traffic path:** User → NGINX Ingress → Frontend (nginx) → Backend (Express) → Elasticsearch
> **Deployment path:** `git push` → GitHub Actions (test · scan · build) → Docker Hub (commit-SHA tags) → reviewed GitOps manifest change → Argo CD syncs → Kubernetes

## 📸 Application Preview

<img src="img/elastiflix2-readme.gif" alt="Elastiflix App Demo" width="840"/>

---

## 🏗️ Architecture

<img src="img/elastiflix-architecture.svg" alt="Elastiflix architecture — build, secure, ship, observe" width="100%"/>

### The flow, end to end

1. **A developer pushes** to a branch / opens a PR. `devsecops.yml` fans out to parallel gates: code tests, Gitleaks, dependency audits, Hadolint, SonarCloud, Trivy, Checkov.
2. **On merge to `main`** the same gates go green, then `docker-push` builds both images with `docker/build-push-action` and pushes them to Docker Hub tagged with the **commit SHA** (never `latest`).
3. CI reports the published image references but does **not** mutate the GitOps configuration. A maintainer proposes the new image tags in a reviewed manifest change.
4. **Argo CD** watches the configured repository paths (automated sync + `selfHeal` + `prune`) and converges the cluster after the reviewed manifest change is merged.
5. The frontend Rollout now declares stable/canary Services, progressive traffic weights (**10% → 25% → 50% → 100%**) and a Prometheus AnalysisTemplate. Minikube uses the NGINX traffic router; EKS uses the ALB router. Runtime controller compatibility and controlled-abort behavior remain to be validated.
6. At runtime, **NGINX Ingress** routes `elastiflix.local` → frontend and `api.elastiflix.local` → backend in Minikube. The separate EKS ALB Ingress remains gated on approved ACM certificate and DNS values.
7. The **backend** serves search (lexical / semantic / hybrid / rerank), answers autocomplete, caches responses in **Redis**, publishes search analytics events to **RabbitMQ**, and exposes `/metrics` + `/healthz`.
8. **Observability components** include Filebeat/Metricbeat → Logstash → Elasticsearch → Kibana for logs and kube-prometheus-stack for metrics. Alertmanager remains disabled pending an approved receiver; `minio.yaml` is not a complete backup solution and Velero schedules/restore automation are not configured.

> Search data model: the catalog (`data-loader/movies/movies.json.gz`) is bulk-indexed by `data-loader/index-data.py`, which derives the `user_score` facet from TMDB `vote_average` and pulls ELSER/E5 inference pipelines (`data-loader/config/`) so the same index serves BM25, vector semantic, hybrid, and reranked retrieval.

---

## 🧰 Tech Stack & Tools — what each one does and why

### 🎬 Application tier

| Tool | Used for | Why it's here |
|---|---|---|
| **React 18** | Frontend SPA | Component model for a faceted, instant-search UI |
| **@elastic/eui + react-search-ui** | Design system & search state | Elastic's own search framework — hosted search UI, facets, pagination, autocomplete out of the box |
| **react-router v5 · Sass · CRA** | Routing & styling | Routes (`/` → `/home`, search results) with scoped styles; Create React App toolchain |
| **NGINX** (`nginxinc/nginx-unprivileged`) | Frontend production host | Static file serving on **8080 as non-root**, relative `/api` proxying to the backend |
| **Node.js 22 · Express 4 (ESM)** | Backend API | Thin orchestration layer: query DSL → Elasticsearch → JSON; ES modules, `/healthz` for K8s probes |
| **@elastic/search-ui-elasticsearch-connector** | Query building | Translates `react-search-ui` state (filters, sort, pagination, queryConfig) into Elasticsearch DSL — no hand-written queries |
| **Structured JSON logging** (zero-dep) | Log pipeline feed | One JSON object per line — Filebeat can aggregate on `path`, `status`, `duration_ms`, `search_type` |

### 🔎 Search & data tier

| Tool | Used for | Why it's here |
|---|---|---|
| **Elasticsearch 9.1** | Search engine & document store | BM25 lexical search **plus** vector semantic (**ELSER / E5 `dense_vector`)**, hybrid retrieval, and reranking — one index (`elastiflix-movies`) serves all four modes |
| **Python `data-loader`** | Catalog ingestion | `index-data.py` bulk-indexes `movies.json.gz`, stringifies `id` for the keyword mapping, derives `user_score` from `vote_average`; unit-tested, 98% line coverage |
| **Logstash 9.1** | Ingest & transform | Parses/enriches app logs → indices; installs index templates (`logs-template`, `movies-template`) before ingesting |
| **Kibana 9.1** | Visualization | Ready-made movies / logs / infrastructure dashboards (`elk/`, `load-dashboards.sh`) |
| **Filebeat 9.1** | Log shipping | Reads container logs from `/var/lib/docker/containers`, ships to Logstash :5044 |
| **Metricbeat 9.1** | Metrics shipping | Container & host metrics + ~112 prebuilt dashboards into Kibana |
| **Redis 7** | Response cache | `SETEX search:<sha256>` keyed on the **full** `react-search-ui` state + `queryConfig`, 300 s TTL; backend **fails open** when Redis is down |
| **RabbitMQ 3** | Search-event bus | `search_events` queue carries `{term, count, ts}` — 24 h TTL, 10k-message cap, `drop-head` overflow so a silent consumer can't balloon the queue |

### ☁️ Platform & orchestration

| Tool | Used for | Why it's here |
|---|---|---|
| **Docker (multi-stage builds)** | Packaging | `frontend/Dockerfile.prod` (CRA build → unprivileged nginx), `backend/Dockerfile.prod` (deps → runtime, npm removed, `USER node`) |
| **Docker Compose** | Local one-shot ELK | Full stack + beats + app in one command (`start.sh`) — the fastest way to hack on this repo |
| **Kubernetes (Minikube / EKS)** | Container orchestration | Namespaces: `elastiflix`, `infra` (Redis/RabbitMQ), `elastic-stack`, `monitoring`, `argocd`, `velero` |
| **NGINX Ingress Controller** | Local app routing | Local-only HTTP host rules for the app and API; Argo CD, Kibana, and Grafana are not exposed by Ingress |
| **Argo Rollouts** | Progressive delivery | Frontend uses NGINX (Minikube) or ALB (EKS) traffic routing, stable/canary Services and Prometheus analysis; live controller compatibility and abort/rollback behavior remain unvalidated |
| **Helm** | Chart management | Infra values (`helm/elasticsearch`, `helm/redis`, `helm/rabbitmq`) + installs Argo CD, ESO, ALB controller, kube-prometheus-stack |

### 🔁 GitOps & delivery

| Tool | Used for | Why it's here |
|---|---|---|
| **Argo CD** | Continuous delivery | Local and EKS App-of-Apps roots register environment-specific child Applications; a restricted `elastiflix` AppProject limits source repositories, destinations and cluster-scoped kinds. EKS workload sync remains manual until the approved ALB Ingress is healthy |
| **Docker Hub** (`an619/elastiflix-*`) | Image registry | Images are published with commit-SHA tags; tag immutability is not enforced at the registry |
| **Local Kubernetes secrets** | Minikube development | Bootstrap requires unique random passwords and creates namespace-scoped Secrets through short-lived private files; no credentials are committed |
| **External Secrets Operator** | Cloud secrets sync | EKS: syncs AWS Secrets Manager → Kubernetes Secrets via a dedicated **IRSA** service account (no static AWS keys); IRSA role scoped to `secret:elastiflix/*` |
| **GitHub Actions** | CI/CD engine | Reusable workflows fanned out by `devsecops.yml`; all third-party actions **pinned to commit SHAs** |
| **MinIO manifest** | Local S3-compatible storage experiment | `minio.yaml` contains a service/deployment, but no Velero schedule, persistent storage, or tested restore workflow |
| **GitOps promotion** | Deployment change control | CI publishes image references; a maintainer must propose and review manifest updates before Argo CD deploys them |

### 🛡️ DevSecOps & quality gates

| Gate | Tool | When | Failure behavior |
|---|---|---|---|
| Code tests | **Jest (frontend)** · **`node --test` + supertest (backend)** · **`terraform validate`** · **kubeconform** | PR + main | build fails |
| Secret scanning | **Gitleaks** | PR + main | build fails |
| Dependency audit | **npm audit** — frontend full tree with exact, expiring build-toolchain exceptions; frontend production tree and backend at HIGH+ · **pip-audit** | PR + main | build fails |
| Dockerfile lint | **Hadolint** (prod & dev Dockerfiles) | PR + main | build fails |
| SAST | **SonarCloud** — Quality Gate: 0 new issues, **≥ 80% coverage on new code**, 0% duplication | PR + main | build fails |
| Image / filesystem scan | **Trivy** — blocks fixable CRITICAL/HIGH findings; reports all CRITICAL/HIGH findings, including unfixed | PR + main | build fails |
| IaC scan | **Checkov** — Terraform and Kubernetes **hard gates**; Kubernetes currently has no skipped checks | PR + main | fails |
| Action hygiene | **SHA-pinned actions**, minimal `permissions:`, `docker-push` main-only | always | — |

### 📊 Observability

| Tool | Scope |
|---|---|
| **kube-prometheus-stack 58.2.2** (Argo CD app) | Prometheus + Grafana; Alertmanager disabled; namespace `monitoring`; Grafana is accessed with a local `kubectl port-forward`, not Ingress |
| **App + infrastructure metrics** | Backend `/metrics` exports bounded response/status and latency histograms plus Redis gauges; ServiceMonitors, SLO burn-rate rules, and Grafana dashboards include a proposed 99.5% rolling 7-day availability target (not an approved SLA). Prometheus/alert delivery remains runtime-unvalidated; Alertmanager notifications are disabled pending an approved receiver |
| **Kibana dashboards** | Movies catalog explore, application logs, infrastructure health (`elk/`, `load-dashboards.sh`) |
| **Structured logs** | `level`, `service`, `path`, `status`, `duration_ms`, `search_type`, `cache_hit` per line |

### 🏗️ Infrastructure as code

| Tool | Used for |
|---|---|
| **Terraform** | AWS: VPC, **EKS** (private managed nodes and private API by default), IAM/**IRSA** roles (ESO, ALB controller), **private bastion** (no public IP, SSM access, HTTPS-only egress), EKS OIDC. `terraform fmt -check` + `validate` run in CI; Checkov is the hard gate |
| **Ansible** | EKS bootstrap: namespaces/PSA labels → Argo CD → Argo Rollouts → ESO (IRSA) → AWS Load Balancer Controller → GitOps Application registration |
| **AWS** | EKS, EC2 bastion, IAM/IRSA, Secrets Manager, VPC/NAT, ALB |
| **kubeseal** | Not used by the current environment-specific secret path; local credentials are generated at bootstrap and EKS credentials are synced through ESO |

---

## 🚀 Quick Start

Pick one workflow — all three run the same app:

### 1. Docker Compose (local ELK demo, ~5 min)

Requirements: Docker Desktop with **≥ 8 GB** RAM, Docker Compose **v2.26+** (environment-sourced secrets), and Python 3.

```bash
git clone https://github.com/An619/Elastiflix.git && cd Elastiflix
export REDIS_PASSWORD="$(openssl rand -hex 32)"
export RABBITMQ_PASSWORD="$(openssl rand -hex 32)"
./start.sh        # stores Redis secret in ignored .secrets/, then starts Compose
```

| Service | URL |
|---|---|
| Elastiflix | http://localhost:3000 |
| Kibana | http://localhost:5601 |
| Elasticsearch | http://localhost:9200 |
| RabbitMQ management | http://localhost:15672 (`user` / password supplied through `RABBITMQ_PASSWORD`) |

See [README-ELK.md](README-ELK.md) for the Elastic Stack walkthrough and [LEARN.md](LEARN.md) for concepts.

### 2. Minikube + GitOps (local Kubernetes)

```bash
export REDIS_PASSWORD="$(openssl rand -hex 32)"
export RABBITMQ_PASSWORD="$(openssl rand -hex 32)"
./bootstrap.sh            # minikube + pinned Argo CD/Rollouts/Falco + GitOps apps
minikube tunnel           # in a separate admin shell, if required for Ingress
```

The bootstrap rejects missing, short, reused passwords, and Redis values outside letters/digits/underscore/hyphen; it writes them through short-lived mode-0600 files into Minikube Secrets and never commits or prints them. Argo CD stays on TLS and uses its generated initial admin password; connect only with `kubectl -n argocd port-forward svc/argocd-server 8080:443` and retrieve the password from `argocd-initial-admin-secret`. The app remains at `http://elastiflix.local`; local development ingress is not production TLS. Kibana and Grafana have no Ingress resources; access them with `kubectl -n elastic-stack port-forward svc/kibana 5601:5601` and `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80`.

### 3. AWS EKS (Terraform + Ansible)

AWS deployment is intentionally **not** automatic. Review the network, state-backend, version, and cost assumptions before running any `apply` command. EKS control-plane hours, EC2 nodes/bastion, NAT gateways, ALB, EBS, S3 and DynamoDB may incur charges; check current regional pricing and review a Terraform plan first.

Bootstrap the remote-state bucket, KMS key, and lock table only after reviewing `terraform/backend-bootstrap/README.md` and the current AWS costs; first confirm an approved existing audit bucket is configured to receive S3 server access logs. The bootstrap uses local state and creates AWS resources; it has not been run from this repository. Then create private local copies of the dev backend/tfvars examples, set the output bucket/table/KMS key values, choose a supported EKS Kubernetes version, and replace the AZ placeholders with three names verified in the target account and region before initializing/planning the environment explicitly:

```bash
cp terraform/environments/dev.backend.hcl.example terraform/environments/dev.backend.hcl
cp terraform/environments/dev.tfvars.example terraform/environments/dev.tfvars
# Fill in the owned state bucket/table and a reviewed cluster_version first.
terraform -chdir=terraform init -backend-config=environments/dev.backend.hcl
terraform -chdir=terraform plan -var-file=environments/dev.tfvars -out=dev.tfplan
```

The EKS API stays private unless you supply a restricted public CIDR list. Before registering the AWS Ingress Application, add an approved ACM certificate ARN and the service's DNS hostname to `kubernetes/aws/ingress-aws.yaml`; the listener is HTTPS-only and intentionally has no HTTP fallback. After provisioning is explicitly approved, run the bootstrap from a network that can reach the private API and export the actual Terraform outputs:

```bash
export EKS_CLUSTER_NAME="$(terraform -chdir=terraform output -raw eks_cluster_name)"
export ALB_CONTROLLER_ROLE_ARN="$(terraform -chdir=terraform output -raw alb_controller_role_arn)"
export ESO_ROLE_ARN="$(terraform -chdir=terraform output -raw eso_role_arn)"
ansible-playbook --syntax-check ansible/playbook.yml
ansible-playbook ansible/playbook.yml
# Only after setting the ACM certificate ARN above and approving deployment:
kubectl apply -f kubernetes/argocd-aws-ingress.yaml
```

Reach a private API through an approved SSM/bastion or VPN path; do not run Ansible from an unreachable laptop network. No AWS resources are provisioned by CI. See [Terraform/AWS Phase 2 status](docs/security/phase-2-terraform-aws.md), [Phase 3 Kubernetes status](docs/security/phase-3-kubernetes-security-reliability.md), [Phase 4 progressive-delivery status](docs/security/phase-4-gitops-progressive-delivery.md), [Phase 5 SRE/SLO status](docs/security/phase-5-sre-observability.md), and [FROM-SCRATCH.md](FROM-SCRATCH.md).

---

## 📂 Project layout

```
frontend/          React 18 SPA (@elastic/eui, react-search-ui) + nginx prod image
backend/           Express (ESM) API — search/semantic/hybrid/rerank + cache + events
data-loader/       Python bulk indexer for the movie catalog (+ config templates)
elk/               Filebeat · Metricbeat · Logstash (pipelines, index templates)
kubernetes/        application/ base · environments/ (Minikube/EKS overlays) · gitops/ (App-of-Apps) · infra/ · elastic-stack/ · aws/
helm/              pinned Argo CD config + values for Elasticsearch / Redis / RabbitMQ charts
terraform/         VPC · EKS · IAM/IRSA · ALB · bastion (private, SSM)
ansible/           Cluster bootstrap (Argo CD · External Secrets · ALB controller)
.github/workflows/ DevSecOps pipeline (reusable workflows + SHA-pinned actions)
```

## ⚙️ Environment variables

| Variable | Where | Purpose |
|---|---|---|
| `PUBLIC_HOST` | backend, frontend | Browser-reachable host for CORS / API URL (default `localhost`) |
| `ES_HOST` / `ES_INDEX` / `ES_API_KEY` | backend | Elasticsearch endpoint, index, optional API key |
| `REDIS_URL` *or* `REDIS_HOST` + `REDIS_PASSWORD` | backend | Redis cache; backend runs fine without it |
| `RABBITMQ_URL` *or* `RABBITMQ_HOST` + `RABBITMQ_USER`/`RABBITMQ_PASSWORD` | backend | Events to RabbitMQ; optional |
| `LOCAL` | backend | `true` enables CORS for the dev origins only |
| `REDIS_PASSWORD` / `RABBITMQ_PASSWORD` | Local `start.sh` / `bootstrap.sh`, AWS Secrets Manager / ESO | Supply unique random local values; Compose mounts `REDIS_PASSWORD` as a file-backed secret (not a Redis/backend environment variable). AWS production values sync from Secrets Manager; never commit credentials |

## 🧪 Tests

```bash
# backend — 40 tests, supertest + in-memory module mocks (Redis/RabbitMQ)
cd backend && npm ci && npm run test:coverage      # lcov in backend/coverage/

# frontend — 13 tests (CRA/jest)
cd frontend && npm ci --legacy-peer-deps && CI=true npm test -- --watchAll=false

# data-loader — 8 tests, zero third-party deps required
cd data-loader && python3 test_index_data.py

# terraform
cd terraform && terraform fmt -check -recursive && terraform init -backend=false && terraform validate
```

CI enforces **≥ 80% coverage on new code** via the SonarCloud Quality Gate.

## 🔐 Security highlights

- Non-root containers everywhere (`USER node`, nginx-unprivileged), `runAsNonRoot`, `drop: [ALL]` capabilities, `allowPrivilegeEscalation: false`
- No public IPs on compute; the bastion lives in a **private subnet** and is reached via **AWS SSM** only (443 egress + HTTP/80 strictly for Ubuntu APT)
- Secrets: unique local credentials are injected at bootstrap and stored as Kubernetes Secrets; EKS secrets sync from AWS Secrets Manager through ESO + IRSA. No credentials are committed; Gitleaks scans every push
- Supply chain: **SHA-pinned actions**, exact expiring frontend build-toolchain exceptions plus production dependency audits, **Trivy** filesystem/image gates, **Checkov** IaC gate, **SonarCloud** SAST gate, and Dependabot updates
- Published images are configured for BuildKit SBOM/provenance attestations and Cosign signing plus digest verification; SHA tags themselves are not registry-immutable
- Least-privilege RBAC (`kubernetes/application/rbac`), per-tier namespaces, image tags bound to commit SHAs

## 📚 Docs

- [README-ELK.md](README-ELK.md) — Elastic Stack one-shot guide
- [FROM-SCRATCH.md](FROM-SCRATCH.md) — build the whole stack from zero
- [LEARN.md](LEARN.md) — concepts & learning path
- [DEMO.md](DEMO.md) — **interview / demo runbook**: 10-minute scripted walkthrough + likely Q&A
- [CHANGELOG.md](CHANGELOG.md) — what changed and why
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to work on this repo (gates, layout, PR rules)
- [SECURITY.md](SECURITY.md) — vulnerability reporting & security posture
- [docs/adr](docs/adr/README.md) — architecture decision records (why GitOps, why SHA tags, why canary)

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: PRs to `main` only, CI must be green (tests · audits · Hadolint · SonarCloud Quality Gate · Trivy · Checkov · Gitleaks · kubeconform), and all third-party actions are SHA-pinned. Security issues go to the private channel in [SECURITY.md](SECURITY.md), never to public issues.

## 📜 License

MIT — see [LICENSE](LICENSE).
