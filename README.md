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
        
        Prometheus[🔥 Prometheus] -->|Scrapes| Backend
        Prometheus -->|Scrapes| Frontend
        Grafana[📈 Grafana] --> Prometheus
        
        %% Security
        Falco[🦅 Falco] -.->|Runtime Alerts| Alert[🚨 Security Alert]
        SealedSecrets[🔐 Sealed Secrets] -.->|Decrypts| Backend
    end
    
    %% External Access
    User([🌍 End User]) --> Ingress