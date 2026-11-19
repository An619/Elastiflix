#!/bin/bash

echo "🚀 1. Starting Minikube..."
minikube start --cpus=4 --memory=7500 --disk-size=30g
minikube addons enable ingress

echo "🐳 2. Loading Docker images into Minikube (Fixing ImagePullBackOff)..."
# We load the images locally so K8s doesn't have to pull from Docker Hub
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

echo "🔄 7. Deploying Argo CD Applications (App of Apps)..."
kubectl apply -f kubernetes/argocd-app.yaml
kubectl apply -f kubernetes/argocd-infra.yaml
kubectl apply -f kubernetes/argocd-elk.yaml
kubectl apply -f kubernetes/argocd-monitoring.yaml
kubectl apply -f kubernetes/argocd-ingress.yaml
kubectl apply -f kubernetes/monitoring-ingress.yaml

echo ""
echo "✅ BOOTSTRAP COMPLETE! Everything is deployed via GitOps."
echo "⚠️  IMPORTANT: You must run these commands in an Administrator PowerShell:"
echo "   net stop was /y"
echo "   minikube tunnel"
echo ""
echo "🔑 Argo CD Login: http://argocd.local | admin / admin123"