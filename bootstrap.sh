#!/bin/bash

echo "🚀 Starting Minikube..."
minikube start --cpus=4 --memory=7500 --disk-size=30g
minikube addons enable ingress

echo "📦 Installing Argo CD..."
kubectl create namespace argocd || true
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "⏳ Waiting for Argo CD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo "🔄 Deploying Argo CD Applications (App of Apps)..."
kubectl apply -f kubernetes/argocd-app.yaml
kubectl apply -f kubernetes/argocd-infra.yaml
kubectl apply -f kubernetes/argocd-elk.yaml
kubectl apply -f kubernetes/argocd-monitoring.yaml
kubectl apply -f kubernetes/argocd-ingress.yaml
kubectl apply -f kubernetes/monitoring-ingress.yaml

echo "✅ Bootstrap complete! Argo CD is now rebuilding your apps from GitHub."
echo "⚠️  Don't forget to run 'minikube tunnel' in an Admin PowerShell window!"