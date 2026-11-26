#!/usr/bin/env bash
# Read-only Phase 3 cluster inventory. This script never applies, patches,
# deletes, execs into, or port-forwards against a cluster.
set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 127
fi

context="$(kubectl config current-context 2>/dev/null || true)"
if [[ -z "$context" ]]; then
  echo "No current kubectl context is configured" >&2
  exit 2
fi

printf 'Phase 3 read-only report\nContext: %s\n\n' "$context"

run_section() {
  local title="$1"
  shift
  printf '\n== %s ==\n' "$title"
  if ! "$@"; then
    printf 'WARN: command failed or this API is not available in the selected cluster.\n'
  fi
}

run_section "Cluster nodes" kubectl get nodes -o wide
run_section "Metrics API nodes" kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
run_section "Application HPAs and PDBs" kubectl get hpa,pdb -n elastiflix
run_section "Application, infra, and Elastic Stack workload readiness" \
  kubectl get pods -n elastiflix -o wide
run_section "Infra workloads" kubectl get pods -n infra -o wide
run_section "Elastic Stack workloads" kubectl get pods -n elastic-stack -o wide
run_section "Monitoring workloads" kubectl get pods -n monitoring -o wide
run_section "NetworkPolicies" kubectl get networkpolicies -A
run_section "Application and AWS ingress" kubectl get ingress -n elastiflix -o wide

if kubectl api-resources --api-group=external-secrets.io -o name 2>/dev/null | grep -q .; then
  run_section "External Secrets status (metadata only)" kubectl get externalsecrets.external-secrets.io -A
  run_section "Cluster SecretStores (metadata only)" kubectl get clustersecretstores.external-secrets.io
else
  printf '\n== External Secrets ==\nWARN: External Secrets CRDs are not installed.\n'
fi

if kubectl api-resources --api-group=monitoring.coreos.com -o name 2>/dev/null | grep -q .; then
  run_section "Prometheus monitors and rules" kubectl get servicemonitors,prometheusrules -n monitoring
else
  printf '\n== Prometheus resources ==\nWARN: Prometheus Operator CRDs are not installed.\n'
fi

printf '\nReport complete. No cluster resources were changed.\n'
