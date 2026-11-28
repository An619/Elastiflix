#!/bin/bash
# Local (Minikube) bootstrap for Elastiflix.
#
# This is a convenience script, not a security boundary: it installs a demo
# cluster on your machine. It still avoids the mistakes that made the previous
# version unsafe to reuse - a published admin password, "stable" branch
# manifests, and a plaintext Argo CD Ingress.
#
# Everything it installs is version-pinned. Bump the pins in a reviewed change.
set -euo pipefail

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.6.3}"
ARGO_ROLLOUTS_VERSION="${ARGO_ROLLOUTS_VERSION:-v1.10.2}"
SEALED_SECRETS_VERSION="${SEALED_SECRETS_VERSION:-v0.27.3}"
FALCO_CHART_VERSION="${FALCO_CHART_VERSION:-9.2.2}"

echo "🚀 1. Starting Minikube..."
# Calico is required for NetworkPolicy enforcement; the default CNI accepts
# NetworkPolicy objects and ignores them, which looks identical to a working
# policy until traffic that should be blocked gets through.
minikube start --cpus=4 --memory=7500 --disk-size=30g --cni=calico
minikube addons enable ingress

echo "🐳 2. Building and loading local images..."
# Build what this checkout actually contains instead of loading whatever
# <image>:latest happens to be on the daemon. The manifests reference a commit
# SHA, so the tag below is deliberate: overriding it locally is a local-only
# change, never a commit.
GIT_SHA="$(git rev-parse HEAD)"
for component in frontend backend; do
  docker build -f "${component}/Dockerfile.prod" -t "an619/elastiflix-${component}:${GIT_SHA}" "./${component}"
  minikube image load "an619/elastiflix-${component}:${GIT_SHA}"
done

echo "📦 3. Installing Argo CD ${ARGOCD_VERSION}..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# Pinned release, not the moving `stable` branch.
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "⏳ 4. Waiting for Argo CD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo "🔧 5. Configuring Argo CD..."
# HTTP behind the local ingress. Acceptable for Minikube only.
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true"}}'

# No known-password patch. The previous version wrote a fixed bcrypt hash for
# "admin123" into argocd-secret, which is a published credential.
ARGOCD_ADMIN_PASSWORD="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [[ -z "${ARGOCD_ADMIN_PASSWORD}" ]]; then
  echo "⚠️  Argo CD did not generate an initial admin password; set one with 'argocd account update-password'."
fi

kubectl rollout restart deployment argocd-server -n argocd
kubectl wait --for=condition=available --timeout=120s deployment/argocd-server -n argocd

echo "🚀 6. Installing Argo Rollouts ${ARGO_ROLLOUTS_VERSION}..."
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argo-rollouts \
  -f "https://raw.githubusercontent.com/argoproj/argo-rollouts/${ARGO_ROLLOUTS_VERSION}/manifests/install.yaml"

echo "🦅 7. Installing Falco (runtime security)..."
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm upgrade --install falco falcosecurity/falco -n falco --create-namespace \
  --version "${FALCO_CHART_VERSION}" \
  --set driver.kind=modern_ebpf --set tty=true --wait

echo "🔐 7b. Installing SealedSecrets controller ${SEALED_SECRETS_VERSION}..."
kubectl apply -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml"

echo "🔑 7c. Creating local Secrets for Minikube (no ESO / AWS on this cluster)..."
# The SealedSecret ciphertexts in kubernetes/infra/ were sealed against another
# cluster's key and cannot decrypt here, so create plain Secrets locally.
# Credentials are generated or supplied via the environment; they are never
# defaulted to a known value and never written to the repository.
random_password() {
  # openssl is used only for a local demo credential; fall back to /dev/urandom
  # so the script does not fail on a machine without it.
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}
REDIS_PASSWORD="${REDIS_PASSWORD:-$(random_password)}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-$(random_password)}"
kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace elastiflix --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic redis-secret -n infra \
  --from-literal=redis-password="${REDIS_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic rabbitmq-secret -n infra \
  --from-literal=rabbitmq-password="${RABBITMQ_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic backend-secret -n elastiflix \
  --from-literal=redis-password="${REDIS_PASSWORD}" \
  --from-literal=rabbitmq-password="${RABBITMQ_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "🔄 8. Deploying Argo CD project and Applications (GitOps)..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f kubernetes/namespaces/namespaces.yaml
kubectl apply -f kubernetes/argocd-project.yaml
kubectl apply -f kubernetes/argocd-namespaces.yaml
kubectl apply -f kubernetes/argocd-app.yaml
kubectl apply -f kubernetes/argocd-infra.yaml
kubectl apply -f kubernetes/argocd-elk.yaml
kubectl apply -f kubernetes/argocd-monitoring.yaml
kubectl apply -f kubernetes/argocd-ingress.yaml
kubectl apply -f kubernetes/monitoring-ingress.yaml

# --- Local image overlay -----------------------------------------------------
# Argo CD syncs `main`, whose manifests carry the *promoted* image tag. The
# images this script built are tagged with this checkout's commit, so without
# the overlay both application pods sit in ImagePullBackOff. Apply a rendered
# copy with the local tag AND switch that Application to manual sync, or
# selfHeal reverts the tag within a few minutes.
echo "🏷️  9. Pointing the application at the locally built images (${GIT_SHA})..."
kubectl -n argocd patch application elastiflix --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT
cp -R kubernetes/application "${RENDER_DIR}/application"
sed -i.bak "s|an619/elastiflix-backend:.*|an619/elastiflix-backend:${GIT_SHA}|" \
  "${RENDER_DIR}/application/backend/deployment.yaml"
sed -i.bak "s|an619/elastiflix-frontend:.*|an619/elastiflix-frontend:${GIT_SHA}|" \
  "${RENDER_DIR}/application/frontend/deployment.yaml"
rm -f "${RENDER_DIR}"/application/*/deployment.yaml.bak
kubectl apply -f "${RENDER_DIR}/application"

echo "⏳ 10. Waiting for the application to become ready..."
kubectl -n elastiflix rollout status deployment/backend --timeout=300s
kubectl -n elastiflix rollout status rollout/frontend --timeout=300s

echo ""
echo "✅ Bootstrap complete. Argo CD 3.6.3, Rollouts ${ARGO_ROLLOUTS_VERSION}, Falco ${FALCO_CHART_VERSION}."
echo "⚠️  Open an Administrator PowerShell and run: net stop was /y && minikube tunnel"
echo ""
# Local Minikube-only address; there is no TLS in front of it by design.
echo "🔑 Argo CD: http://argocd.local | user: admin" # NOSONAR - local cluster address, not a credential
if [[ -n "${ARGOCD_ADMIN_PASSWORD}" ]]; then
  echo "   initial password: ${ARGOCD_ADMIN_PASSWORD}"
  echo "   Change it immediately: argocd account update-password"
else
  echo "   initial password: retrieve with 'kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath={.data.password} | base64 -d'"
fi
echo ""
echo "ℹ️  Images deployed: an619/elastiflix-{frontend,backend}:${GIT_SHA}"
echo "   The elastiflix Application is set to manual sync so selfHeal does not"
echo "   revert the local tag. Re-enable automated sync before testing GitOps."
echo ""
echo "📚 Elasticsearch starts empty and Logstash indexes the catalogue in the"
echo "   background; first search may return nothing for a few minutes."
echo "   Watch it:  kubectl -n elastic-stack logs deploy/logstash -c prepare-data -f"
echo ""
# Rollout status only proves the pods started, not that the app answers queries.
echo "🔎 Verify it end to end:  ./scripts/verify-deployment.sh"
