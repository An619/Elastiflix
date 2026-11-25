# 🎬 Elastiflix - Enterprise DevSecOps & GitOps Project

![Docker](https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)
![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=for-the-badge&logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-232F3E?style=for-the-badge&logo=amazon-aws&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-2088FF?style=for-the-badge&logo=github-actions&logoColor=white)
![ArgoCD](https://img.shields.io/badge/Argo_CD-EF7B4D?style=for-the-badge&logo=argo&logoColor=white)

A production-grade, 3-tier application (React / Node.js / Elasticsearch) deployed using a fully automated DevSecOps and GitOps pipeline. This project demonstrates best practices in CI/CD, security, observability, and cloud-native architecture.

## 📸 Application Preview

<img src="img/elastiflix2-readme.gif" alt="Elastiflix App Demo" width="800"/>

## 🚀 Quick Start

Pick one workflow — all three run the same app:

### 1. Docker Compose (local ELK demo)

Requirements: Docker Desktop with **at least 8 GB** RAM, Python 3.

```bash
git clone https://github.com/An619/Elastiflix.git
cd Elastiflix
./start.sh
```

| Service | URL |
|---|---|
| Elastiflix | http://localhost:3000 |
| Kibana | http://localhost:5601 |
| Elasticsearch | http://localhost:9200 |

See [README-ELK.md](README-ELK.md) for the full Elastic Stack walkthrough and [LEARN.md](LEARN.md) for concepts.

### 2. Minikube + GitOps (local Kubernetes)

```bash
./bootstrap.sh
# then in an admin PowerShell:
#   minikube tunnel
```

Argo CD UI: http://argocd.local (`admin` / `admin123`).

### 3. AWS EKS (Terraform + Ansible)

```bash
cd terraform
terraform init
terraform apply
cd ..
ansible-playbook ansible/playbook.yml
```

## 🏗️ Architecture Diagram

```mermaid
graph TD
    %% CI/CD Pipeline
    Dev([👨‍💻 Developer]) -->|git push| GitHub[🐙 GitHub Repo]
    GitHub -->|Triggers| GHA[⚙️ GitHub Actions]

    subgraph "DevSecOps Scanners"
        GHA -->|SAST| Sonar[☁️ SonarCloud]
        GHA -->|Secret Scan| Gitleaks[🔍 Gitleaks]
        GHA -->|Container Scan| Trivy[🛡️ Trivy]
        GHA -->|IaC Scan| Checkov[🏗️ Checkov]
    end

    GHA -->|Build & Push| DockerHub[🐳 Docker Hub]

    %% GitOps & K8s
    ArgoCD[🦑 Argo CD] -->|Syncs State| GitHub
    ArgoCD -->|Deploys via| Rollouts[🚀 Argo Rollouts]

    subgraph "Kubernetes Cluster (Minikube / AWS EKS)"
        Ingress[🌐 NGINX Ingress] -->|elastiflix.local| Frontend[⚛️ React Frontend]
        Ingress -->|api.elastiflix.local| Backend[🟢 Node.js Backend]

        Backend -->|Cache| Redis[(🔴 Redis)]
        Backend -->|Queue| RabbitMQ[(🐰 RabbitMQ)]
        Backend -->|Search| ES[(🔎 Elasticsearch)]

        %% Observability
        Filebeat[📦 Filebeat] -->|Logs| Logstash[🪵 Logstash]
        Logstash --> ES
        ES --> Kibana[📊 Kibana]

        Prometheus[🔥 Prometheus] -->|Scrapes /metrics| Backend
        Grafana[📈 Grafana] --> Prometheus

        %% Security
        Falco[🦅 Falco] -.->|Runtime Alerts| Alert[🚨 Security Alert]
        SealedSecrets[🔐 Sealed Secrets] -.->|Decrypts infra Secrets| Infra[🔴 Redis / 🐰 RabbitMQ]
        ESO[🔑 External Secrets Operator] -.->|Syncs AWS Secrets Manager| Backend
    end

    %% External Access
    User([🌍 End User]) --> Ingress
```

> **Notes:** Prometheus scrapes only the Backend (`GET /metrics` in `backend/src/Backend.js`); the Frontend is a static nginx site with no metrics endpoint. SealedSecrets decrypt the infra Redis/RabbitMQ Secrets; the Backend Secret comes from ESO on EKS (or a plain Secret created by `bootstrap.sh` on Minikube).

## 📚 Docs

- [README-ELK.md](README-ELK.md) — Elastic Stack one-shot guide
- [FROM-SCRATCH.md](FROM-SCRATCH.md) — build the stack from scratch
- [LEARN.md](LEARN.md) — concepts and learning path

## ⚙️ Environment Variables

| Variable | Where | Purpose |
|---|---|---|
| `PUBLIC_HOST` | backend, frontend | Browser-reachable host for CORS / API URL (default `localhost`) |
| `ES_HOST` / `ES_INDEX` | backend | Elasticsearch endpoint and index |
| `REDIS_URL` or `REDIS_HOST` + `REDIS_PASSWORD` | backend | Redis cache (optional — backend runs without it) |
| `RABBITMQ_URL` or `RABBITMQ_HOST` + `RABBITMQ_PASSWORD` | backend | RabbitMQ events (optional) |
| `REDIS_PASSWORD` / `RABBITMQ_PASSWORD` | `bootstrap.sh`, Helm | Local Secret values — never commit real passwords |

## 🧪 Tests

```bash
cd backend && npm ci && npm test
cd ../frontend && npm ci --legacy-peer-deps && CI=true npm test -- --watchAll=false
cd ../terraform && terraform fmt -check -recursive && terraform init -backend=false && terraform validate
```
