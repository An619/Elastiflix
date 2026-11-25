#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "🚀 1. Starting Minikube..."
minikube start --cpus=4 --memory=7500 --disk-size=30g
minikube addons enable ingress

echo "🐳 2. Loading Docker images into Minikube..."
# Load local images to avoid Docker Hub rate limits and errors
minikube image load an619/elastiflix-frontend:latest || true
minikube image load an619/elastiflix-backend:latest || true
minikube image load an619/elastiflix-frontend:v0.1.0 || true
minikube image load an619/elastiflix-backend:v0.1.0 || true

echo "📦 3. Installing Argo CD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "⏳ 4. Waiting for Argo CD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo "🔧 5. Patching Argo CD (HTTP Ingress & Admin Password)..."
# Allow HTTP traffic from Ingress
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
# Reset admin password to admin123
kubectl -n argocd patch secret argocd-secret --type merge -p '{"stringData": {"admin.password": "$2a$12$R9h/cIPz0gi.URNNX3kh2OPST9/PgBkqquzi.Ss7KIUgO2t0jWMUW", "admin.passwordMtime": "2024-01-01T00:00:00Z"}}'
kubectl rollout restart deployment argocd-server -n argocd
kubectl wait --for=condition=available --timeout=120s deployment/argocd-server -n argocd

echo "🚀 6. Installing Argo Rollouts..."
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argo-rollouts -f https://raw.githubusercontent.com/argoproj/argo-rollouts/stable/manifests/install.yaml

echo "🦅 7. Installing Falco (Runtime Security)..."
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm upgrade --install falco falcosecurity/falco -n falco --create-namespace --set driver.kind=modern_ebpf --set tty=true --wait

echo "🔐 7b. Installing SealedSecrets controller..."
kubectl create namespace kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.3/controller.yaml

echo "🔑 7c. Creating local Secrets for Minikube (no ESO / AWS on this cluster)..."
# SealedSecrets ciphertexts in kubernetes/infra/*-sealedsecret.yaml were
# sealed against a different cluster's key and cannot decrypt here, so
# create plain Secrets locally. Override via env vars if needed:
#   REDIS_PASSWORD=... RABBITMQ_PASSWORD=... ./bootstrap.sh
# Create project namespaces with their Pod Security Admission labels before
# workloads or secrets are created. elastiflix/infra enforce the restricted
# profile; namespaces with third-party chart or hostPath workloads only warn.
kubectl apply -f kubernetes/namespaces/namespaces.yaml
kubectl create secret generic redis-secret -n infra \
  --from-literal=redis-password="${REDIS_PASSWORD:-elastiflix-redis-pass}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic rabbitmq-secret -n infra \
  --from-literal=rabbitmq-password="${RABBITMQ_PASSWORD:-elastiflix-rabbit-pass}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic backend-secret -n elastiflix \
  --from-literal=redis-password="${REDIS_PASSWORD:-elastiflix-redis-pass}" \
  --from-literal=rabbitmq-password="${RABBITMQ_PASSWORD:-elastiflix-rabbit-pass}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "🔄 8. Deploying Argo CD Applications (GitOps)..."
kubectl apply -f kubernetes/argocd-app.yaml
kubectl apply -f kubernetes/argocd-infra.yaml
kubectl apply -f kubernetes/argocd-elk.yaml
kubectl apply -f kubernetes/argocd-monitoring.yaml
kubectl apply -f kubernetes/argocd-ingress.yaml
kubectl apply -f kubernetes/monitoring-ingress.yaml

echo ""
echo "✅ BOOTSTRAP COMPLETE! Your local cluster is fully restored via GitOps."
echo "⚠️  IMPORTANT: Open an Administrator PowerShell and run these commands:"
echo "   net stop was /y"
echo "   minikube tunnel"
echo ""
echo "🔑 Argo CD Login: http://argocd.local | admin / admin123"
