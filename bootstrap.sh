#!/usr/bin/env bash

set -euo pipefail

# Local credentials are generated once and kept in the ignored .secrets tree.
# Existing local files or Kubernetes Secrets are reused on reruns so repeating
# this one-command bootstrap does not silently rotate database credentials.
for credential_name in REDIS_PASSWORD RABBITMQ_PASSWORD; do
  credential_value="${!credential_name:-}"
  if [[ -n "$credential_value" ]]; then
    if (( ${#credential_value} < 32 )); then
      echo "$credential_name must be at least 32 characters." >&2
      exit 1
    fi
    if [[ ! "$credential_value" =~ ^[A-Za-z0-9_-]+$ ]]; then
      echo "$credential_name may contain only letters, digits, underscore, or hyphen." >&2
      exit 1
    fi
  fi
done
if [[ -n "${REDIS_PASSWORD:-}" && -n "${RABBITMQ_PASSWORD:-}" && "$REDIS_PASSWORD" == "$RABBITMQ_PASSWORD" ]]; then
  echo "Use different passwords for Redis and RabbitMQ." >&2
  exit 1
fi

ARGOCD_APP_TIMEOUT_SECONDS="${ARGOCD_APP_TIMEOUT_SECONDS:-1800}"
if [[ ! "$ARGOCD_APP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]{0,4}$ ]]; then
  echo "ARGOCD_APP_TIMEOUT_SECONDS must be a positive integer (default: 1800)." >&2
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
elasticsearch_port_forward_pid=""
umask 077

stop_elasticsearch_port_forward() {
  if [[ -z "$elasticsearch_port_forward_pid" ]]; then
    return 0
  fi

  if kill -0 "$elasticsearch_port_forward_pid" 2>/dev/null; then
    kill "$elasticsearch_port_forward_pid"
  fi
  if wait "$elasticsearch_port_forward_pid"; then
    echo "Elasticsearch port-forward exited unexpectedly before shutdown." >&2
    return 1
  else
    local wait_status=$?
    if (( wait_status != 143 )); then
      echo "Elasticsearch port-forward exited with unexpected status $wait_status." >&2
      return "$wait_status"
    fi
  fi
  elasticsearch_port_forward_pid=""
}

cleanup_bootstrap() {
  local exit_status=$?
  trap - EXIT
  if [[ -n "$elasticsearch_port_forward_pid" ]]; then
    if stop_elasticsearch_port_forward; then
      :
    else
      local cleanup_status=$?
      if (( exit_status == 0 )); then
        exit_status="$cleanup_status"
      fi
    fi
  fi
  if rm -rf "$secret_dir"; then
    :
  else
    local cleanup_status=$?
    echo "Could not remove the temporary bootstrap secret directory." >&2
    if (( exit_status == 0 )); then
      exit_status="$cleanup_status"
    fi
  fi
  exit "$exit_status"
}
trap cleanup_bootstrap EXIT
local_secret_dir="${MINIKUBE_SECRET_DIR:-.secrets/minikube}"
mkdir -p "$local_secret_dir"
chmod 700 "$local_secret_dir"

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
current_context="$(kubectl config current-context)"
if [[ "$current_context" != "minikube" ]]; then
  echo "Minikube start selected kubectl context '$current_context' instead of 'minikube'; refusing to continue." >&2
  exit 2
fi
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

echo "🔐 7. Reusing or creating private local application credentials..."
# Use short-lived, mode-0600 files rather than placing passwords in process
# arguments, shell history, terminal output, or committed manifests.
ensure_local_password() {
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  local supplied_value="$4"
  local persisted_path="$5"
  local output_path="$6"
  local encoded_path="$secret_dir/${secret_name}.base64"
  local error_path="$secret_dir/${secret_name}.lookup-error"
  local value=""

  if [[ -s "$persisted_path" ]]; then
    value="$(<"$persisted_path")"
  elif kubectl get secret "$secret_name" -n "$namespace" \
    -o "go-template={{index .data \"$key\"}}" > "$encoded_path" 2> "$error_path"; then
    if [[ ! -s "$encoded_path" ]]; then
      echo "Existing Secret $namespace/$secret_name has no '$key' data; refusing to replace it." >&2
      return 1
    fi
    openssl base64 -d -A -in "$encoded_path" -out "$output_path"
    value="$(<"$output_path")"
  elif grep -qiE 'NotFound|not found' "$error_path"; then
    if [[ -n "$supplied_value" ]]; then
      value="$supplied_value"
    else
      value="$(openssl rand -hex 32)"
    fi
  else
    cat "$error_path" >&2
    echo "Could not safely inspect $namespace/$secret_name; refusing to generate replacement credentials." >&2
    return 1
  fi

  if (( ${#value} < 32 )) || [[ ! "$value" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Existing or supplied value for $namespace/$secret_name is not a supported password; refusing to overwrite it." >&2
    return 1
  fi
  if [[ -n "$supplied_value" && "$value" != "$supplied_value" ]]; then
    echo "Supplied credential differs from the existing $namespace/$secret_name value; refusing an implicit credential rotation." >&2
    return 1
  fi

  printf '%s' "$value" > "$output_path"
  chmod 600 "$output_path"
  printf '%s' "$value" > "$persisted_path"
  chmod 600 "$persisted_path"
}

ensure_local_password infra redis-secret redis-password "${REDIS_PASSWORD:-}" \
  "$local_secret_dir/redis-password" "$secret_dir/redis-password"
ensure_local_password infra rabbitmq-secret rabbitmq-password "${RABBITMQ_PASSWORD:-}" \
  "$local_secret_dir/rabbitmq-password" "$secret_dir/rabbitmq-password"
unset REDIS_PASSWORD RABBITMQ_PASSWORD

if [[ "$(<"$local_secret_dir/redis-password")" == "$(<"$local_secret_dir/rabbitmq-password")" ]]; then
  echo "Redis and RabbitMQ passwords must be different; refusing to apply Secrets." >&2
  exit 1
fi

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
  if secret_lookup="$(kubectl get secret elasticsearch-bootstrap -n elastic-stack -o name 2>&1)"; then
    echo "Elasticsearch already has bootstrap credentials but the local TLS/credential bundle is missing." >&2
    echo "Restore the protected $local_elasticsearch_dir files before rerunning; refusing to replace existing credentials." >&2
    exit 2
  elif [[ "$secret_lookup" != *"NotFound"* && "$secret_lookup" != *"not found"* ]]; then
    printf 'Could not inspect the existing Elasticsearch bootstrap Secret: %s\n' "$secret_lookup" >&2
    exit 2
  fi
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
stop_elasticsearch_port_forward

echo "⏳ 9. Waiting for Argo CD to sync every local application..."
wait_for_argocd_application() {
  local application_name="$1"
  local wait_for_health="$2"
  local application_resource="applications.argoproj.io/${application_name}"

  echo "Waiting for ${application_name} to exist and sync..."
  kubectl wait --for=create "$application_resource" -n argocd \
    --timeout="${ARGOCD_APP_TIMEOUT_SECONDS}s"
  kubectl wait --for="jsonpath={.status.sync.status}=Synced" "$application_resource" -n argocd \
    --timeout="${ARGOCD_APP_TIMEOUT_SECONDS}s"
  if [[ "$wait_for_health" == "true" ]]; then
    kubectl wait --for="jsonpath={.status.health.status}=Healthy" "$application_resource" -n argocd \
      --timeout="${ARGOCD_APP_TIMEOUT_SECONDS}s"
  fi
}

wait_for_argocd_application elastiflix-local-root false
for application_name in infra-databases elastic-stack monitoring monitoring-network-policy elastiflix; do
  wait_for_argocd_application "$application_name" true
done

echo "⏳ 10. Waiting for application and dependency workloads to become ready..."
kubectl rollout status deployment/backend -n elastiflix --timeout="${ARGOCD_APP_TIMEOUT_SECONDS}s"
kubectl wait --for="jsonpath={.status.phase}=Healthy" rollout/frontend -n elastiflix \
  --timeout="${ARGOCD_APP_TIMEOUT_SECONDS}s"
kubectl rollout status deployment/redis -n infra --timeout="${ARGOCD_APP_TIMEOUT_SECONDS}s"
kubectl rollout status deployment/rabbitmq -n infra --timeout="${ARGOCD_APP_TIMEOUT_SECONDS}s"
kubectl rollout status statefulset/elasticsearch -n elastic-stack --timeout="${ARGOCD_APP_TIMEOUT_SECONDS}s"
kubectl rollout status deployment/kibana -n elastic-stack --timeout="${ARGOCD_APP_TIMEOUT_SECONDS}s"
kubectl rollout status deployment/logstash -n elastic-stack --timeout="${ARGOCD_APP_TIMEOUT_SECONDS}s"
kubectl rollout status daemonset/filebeat -n elastic-stack --timeout="${ARGOCD_APP_TIMEOUT_SECONDS}s"

for service_name in frontend backend; do
  endpoint_ips="$(kubectl get endpoints "$service_name" -n elastiflix -o jsonpath='{.subsets[*].addresses[*].ip}')"
  if [[ -z "$endpoint_ips" ]]; then
    echo "Service elastiflix/$service_name has no ready endpoints." >&2
    exit 1
  fi
done

echo "✅ Local Argo CD applications are Synced/Healthy and the app/dependency workloads are ready."
kubectl -n argocd get applications
kubectl get pods -n elastiflix -o wide
kubectl get ingress -n elastiflix -o wide
MINIKUBE_IP="$(minikube ip)"
printf 'Minikube IP: %s\nFrontend: http://elastiflix.local\nAPI: http://api.elastiflix.local\n' "$MINIKUBE_IP"
printf 'If these names do not resolve, add this hosts-file mapping: %s elastiflix.local api.elastiflix.local\n' "$MINIKUBE_IP"
printf 'To inspect Argo CD (optional): kubectl -n argocd port-forward svc/argocd-server 8080:443\n'

cat <<'EOF'

Secure Argo CD access:
  kubectl -n argocd port-forward svc/argocd-server 8080:443
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  # Open https://localhost:8080 and sign in as admin with the generated password.

No AWS resources or clusters were touched by this local bootstrap.
EOF
