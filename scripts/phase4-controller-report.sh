#!/usr/bin/env bash
# Read-only inventory of the traffic-routing and Argo Rollouts controller images.
# This does not apply, patch, delete, exec, or port-forward to cluster resources.
set -euo pipefail

provider="${1:-}"
case "$provider" in
  minikube)
    ingress_namespace=ingress-nginx
    ingress_deployment=ingress-nginx-controller
    ingress_class=nginx
    ingress_label="Minikube ingress-nginx"
    ;;
  eks)
    ingress_namespace=kube-system
    ingress_deployment=aws-load-balancer-controller
    ingress_class=alb
    ingress_label="AWS Load Balancer Controller"
    ;;
  *)
    echo "Usage: $0 {minikube|eks}" >&2
    exit 2
    ;;
esac

command -v kubectl >/dev/null 2>&1 || { echo "Required command not found: kubectl" >&2; exit 127; }
context="$(kubectl config current-context)"
get_image() {
  local namespace="$1" deployment="$2"
  kubectl -n "$namespace" get deployment "$deployment" \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
}

rollouts_image="$(get_image argo-rollouts argo-rollouts)"
ingress_image="$(get_image "$ingress_namespace" "$ingress_deployment")"
[[ -n "$rollouts_image" ]] || { echo "Argo Rollouts controller deployment/image not found." >&2; exit 1; }
[[ -n "$ingress_image" ]] || { echo "$ingress_label deployment/image not found." >&2; exit 1; }
[[ "$rollouts_image" == *":v1.10.2" || "$rollouts_image" == *":v1.10.2@sha256:"* ]] || {
  echo "Expected the reviewed Argo Rollouts v1.10.2 pin; found: $rollouts_image" >&2
  exit 1
}
[[ "$ingress_image" != *":latest" ]] || { echo "$ingress_label uses a mutable latest tag; inspect and pin before routing." >&2; exit 1; }
kubectl get ingressclass "$ingress_class" >/dev/null

printf 'Context: %s\n' "$context"
printf 'Argo Rollouts image: %s\n' "$rollouts_image"
printf '%s image: %s\n' "$ingress_label" "$ingress_image"
printf 'IngressClass present: %s\n' "$ingress_class"
printf 'Inventory only; compare these installed versions with the approved compatibility notes before syncing the environment overlay.\n'
