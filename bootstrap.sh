#!/usr/bin/env bash

set -euo pipefail

# Require strong, user-supplied local credentials before starting the cluster.
: "${REDIS_PASSWORD:?Set REDIS_PASSWORD to a unique, random password of at least 32 characters.}"
: "${RABBITMQ_PASSWORD:?Set RABBITMQ_PASSWORD to a unique, random password of at least 32 characters.}"
if (( ${#REDIS_PASSWORD} < 32 || ${#RABBITMQ_PASSWORD} < 32 )); then
  echo "REDIS_PASSWORD and RABBITMQ_PASSWORD must each be at least 32 characters." >&2
  exit 1
fi
if [[ "$REDIS_PASSWORD" == "$RABBITMQ_PASSWORD" ]]; then
  echo "Use different passwords for Redis and RabbitMQ." >&2
  exit 1
fi
if [[ ! "$REDIS_PASSWORD" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "REDIS_PASSWORD may contain only letters, digits, underscore, or hyphen." >&2
  exit 1
fi

for command in minikube kubectl helm openssl curl jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command not found: $command" >&2
    exit 1
  }
done

secret_dir="$(mktemp -d)"
chmod 700 "$secret_dir"
trap 'rm -rf "$secret_dir"' EXIT
umask 077
printf '%s' "$REDIS_PASSWORD" > "$secret_dir/redis-password"
printf '%s' "$RABBITMQ_PASSWORD" > "$secret_dir/rabbitmq-password"
unset REDIS_PASSWORD RABBITMQ_PASSWORD

# This bootstrap is explicitly Minikube-local: refuse an unexpected existing
# context before any cluster mutation, and never touch a remote context.
if kubectl config get-contexts -o name | grep -qx minikube; then
  current_context="$(kubectl config current-context)"
  if [[ "$current_context" != minikube ]]; then
    echo "Current kubectl context is '$current_context', not 'minikube'; switch contexts explicitly and retry." >&2
    exit 2
  fi
fi

echo "🚀 1. Starting Minikube..."
minikube start --cpus=4 --memory=7500 --disk-size=30g
minikube addons enable ingress

echo "📦 2. Preparing application images..."
# Workloads use immutable Docker Hub digests; Argo CD pulls those exact refs.

echo "📦 3. Installing Argo CD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.3/manifests/install.yaml

echo "⏳ 4. Waiting for Argo CD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
kubectl apply -f kubernetes/argocd-rollout-health.yaml

# Keep Argo CD's built-in TLS and generated initial admin password. Access it
# with kubectl port-forward; do not publish its admin interface over HTTP.

echo "🚀 5. Installing Argo Rollouts..."
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argo-rollouts -f https://raw.githubusercontent.com/argoproj/argo-rollouts/v1.10.2/manifests/install.yaml
kubectl wait --for=condition=available --timeout=300s deployment/argo-rollouts -n argo-rollouts
kubectl wait --for=condition=available --timeout=300s deployment/ingress-nginx-controller -n ingress-nginx
scripts/phase4-controller-report.sh minikube

echo "🦅 6. Installing pinned Falco runtime security chart..."
helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update
helm repo update falcosecurity
helm upgrade --install falco falcosecurity/falco --version 9.2.2 \
  --namespace falco --create-namespace \
  --set driver.kind=modern_ebpf --set tty=true --wait --timeout 5m

# Create namespaces with their Pod Security Admission labels before secrets
# or workloads. The AWS/ESO secrets Application is intentionally not applied
# in Minikube; local secrets below are the sole local credential owner.
kubectl apply -f kubernetes/namespaces/namespaces.yaml

echo "🔐 7. Creating local application secrets..."
# Use short-lived, mode-0600 files rather than placing passwords in process
# arguments, shell history, terminal output, or committed manifests.
kubectl create secret generic redis-secret -n infra \
  --from-file=redis-password="$secret_dir/redis-password" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic rabbitmq-secret -n infra \
  --from-file=rabbitmq-password="$secret_dir/rabbitmq-password" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic backend-secret -n elastiflix \
  --from-file=redis-password="$secret_dir/redis-password" \
  --from-file=rabbitmq-password="$secret_dir/rabbitmq-password" \
  --dry-run=client -o yaml | kubectl apply -f -

# Generate a local-only TLS CA/certificate and random bootstrap credentials.
# The security configuration script connects only to the local port-forward;
# no cluster resource is mutated beyond the namespace/Secrets below.
local_elasticsearch_dir="${ELASTICSEARCH_SECRET_DIR:-.secrets/elasticsearch}"
mkdir -p "$(dirname "$local_elasticsearch_dir")"
chmod 700 "$(dirname "$local_elasticsearch_dir")"
trap 'rm -rf "$secret_dir"' EXIT
if [[ ! -s "$local_elasticsearch_dir/ca.crt" ]]; then
  scripts/prepare-elasticsearch-tls.sh "$local_elasticsearch_dir"
else
  for file in ca.crt tls.crt tls.key elastic-password kibana-password; do
    [[ -s "$local_elasticsearch_dir/$file" ]] || {
      echo "Incomplete Elasticsearch credential directory: missing $local_elasticsearch_dir/$file" >&2
      exit 2
    }
  done
fi

kubectl create secret generic elasticsearch-bootstrap -n elastic-stack \
  --from-file=elastic-password="$local_elasticsearch_dir/elastic-password" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic elasticsearch-tls -n elastic-stack \
  --from-file=ca.crt="$local_elasticsearch_dir/ca.crt" \
  --from-file=tls.crt="$local_elasticsearch_dir/tls.crt" \
  --from-file=tls.key="$local_elasticsearch_dir/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -

# Elasticsearch starts under TLS, then users and client API keys are created
# only after its readiness endpoint responds. The persistent local credential
# directory is git-ignored; it must be backed up securely for PVC recovery.
echo "🔄 8. Deploying the local App-of-Apps root..."
kubectl apply -f kubernetes/argocd-project.yaml
kubectl apply -f kubernetes/argocd-local-root.yaml
kubectl -n elastic-stack rollout status statefulset/elasticsearch --timeout=10m
kubectl port-forward -n elastic-stack svc/elasticsearch 19200:9200 >/dev/null 2>&1 &
elasticsearch_port_forward_pid=$!
trap 'kill "$elasticsearch_port_forward_pid" 2>/dev/null || true; rm -rf "$secret_dir"' EXIT
if [[ ! -s "$local_elasticsearch_dir/backend-api-key" || ! -s "$local_elasticsearch_dir/logstash-api-key" ]]; then
  ELASTICSEARCH_SECRET_DIR="$local_elasticsearch_dir" \
    ELASTICSEARCH_URL="https://localhost:19200" \
    scripts/configure-elasticsearch-security.sh
fi

kubectl create secret generic elasticsearch-security -n elastic-stack \
  --from-file=kibana-password="$local_elasticsearch_dir/kibana-password" \
  --from-file=logstash-api-key="$local_elasticsearch_dir/logstash-api-key" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic backend-secret -n elastiflix \
  --from-file=redis-password="$secret_dir/redis-password" \
  --from-file=rabbitmq-password="$secret_dir/rabbitmq-password" \
  --from-file=es-api-key="$local_elasticsearch_dir/backend-api-key" \
  --from-file=es-ca.crt="$local_elasticsearch_dir/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -
kill "$elasticsearch_port_forward_pid" 2>/dev/null || true
wait "$elasticsearch_port_forward_pid" 2>/dev/null || true
trap 'rm -rf "$secret_dir"' EXIT

echo "🔄 9. Confirming the local App-of-Apps root is registered..."
kubectl -n argocd get application elastiflix-local-root

cat <<'EOF'

✅ Local bootstrap submitted. Argo CD sync and workload readiness may take several minutes.

Secure Argo CD access:
  kubectl -n argocd port-forward svc/argocd-server 8080:443
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  # Open https://localhost:8080 and sign in as admin with the generated password.

No AWS resources or clusters were touched by this local bootstrap.
EOF
