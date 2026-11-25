# Phase 3: Kubernetes security and reliability

## Scope and guardrails

This phase follows the requirements in the Elastiflix DevSecOps remediation master prompt. It extends the existing Kubernetes hardening; it does not create a cluster, apply manifests, run a GitOps sync, or provision AWS resources. Changes here describe desired state only.

The repository's earlier `phase-2-kubernetes-hardening.md` label predates alignment to the master prompt's phase numbering. In that prompt, Kubernetes security and reliability is Phase 3.

## Implemented in this increment

- Added CPU-based `autoscaling/v2` HPAs for the backend Deployment and frontend Argo Rollout. Both scale from 2 to 6 replicas at a 70% average CPU target. The cluster must have a functioning Metrics API (for example, metrics-server) for these HPAs to act.
- Added `policy/v1` PodDisruptionBudgets for frontend and backend, keeping at least one matching pod available during voluntary disruptions.
- Enforced the Restricted Pod Security Standard in the `elastiflix` and `infra` namespaces. `elastic-stack` and `monitoring` receive audit/warn labels only: Filebeat still requires hostPath log access, and third-party monitoring chart pods have not been verified against Restricted enforcement.
- Extended the Elastic Stack namespace default-deny policy to cover egress as well as ingress. Existing per-workload policies remain the explicit allow list.
- Removed Filebeat's unused Docker-only `/var/lib/docker/containers` hostPath. Its read-only `/var/log` mount supports the `/var/log/containers/*.log` input used by containerd-based nodes; this still requires runtime verification on Minikube and EKS.
- Updated the Minikube bootstrap to apply the namespace manifests, so the Pod Security Admission labels are present before project workloads are installed.

## Required network flows

NetworkPolicies are additive: if multiple policies select a pod, the permitted traffic is the union of their allow rules. Confirm the CNI actually enforces NetworkPolicy before relying on these controls.

| Namespace / workload | Direction | Allowed peer | Protocol / port | Purpose |
|---|---|---|---|---|
| `elastiflix` frontend | ingress | ALB subnet CIDRs and ingress-nginx controller | TCP/8080 | Browser traffic to frontend |
| `elastiflix` backend | ingress | ALB subnet CIDRs, ingress-nginx controller, frontend pods | TCP/17700 | API traffic |
| `elastiflix` frontend | egress | backend pods | TCP/17700 | Frontend API proxy |
| `elastiflix` backend | egress | CoreDNS | UDP/TCP 53 | Service discovery |
| `elastiflix` backend | egress | Elasticsearch in `elastic-stack` | TCP/9200 | Search requests |
| `elastiflix` backend | egress | Redis in `infra` | TCP/6379 | Cache |
| `elastiflix` backend | egress | RabbitMQ in `infra` | TCP/5672 | Search events |
| `infra` Redis | ingress | backend pods in `elastiflix` | TCP/6379 | Cache access |
| `infra` RabbitMQ | ingress | backend pods in `elastiflix` | TCP/5672 | Event publishing |
| `elastic-stack` Elasticsearch | ingress | Kibana, Logstash, backend | TCP/9200 | Search and indexing |
| `elastic-stack` Kibana | ingress | ingress-nginx controller | TCP/5601 | Local dashboard ingress |
| `elastic-stack` Logstash | ingress | Filebeat | TCP/5044 | Log ingestion |
| `elastic-stack` Logstash | egress | Elasticsearch and approved public destinations | TCP/9200, TCP/443 | Indexing and catalogue bootstrap |
| `elastic-stack` Filebeat | egress | Logstash and configured EKS control-plane subnets | TCP/5044, TCP/443 | Log shipping and Kubernetes metadata |

The ALB/VPC subnet CIDRs and Filebeat control-plane CIDRs must stay synchronized with Terraform. The current Filebeat API rule assumes the private EKS endpoint uses the listed VPC subnets; a public-only endpoint or a different service-CIDR translation needs a separately reviewed rule. Minikube's API endpoint may require an environment-specific allow rule.

## Status checklist

| Requirement | Status | Evidence / next action |
|---|---|---|
| App resource requests/limits and health probes | Complete | Backend and frontend manifests include resource budgets and probes. |
| HPA and PDB for app workloads | Implemented; runtime validation pending | New HPA/PDB manifests. Verify Metrics API and scale/eviction behavior on Minikube. |
| Restricted Pod Security Admission | Partially implemented | Enforced for `elastiflix` and `infra`; `elastic-stack` and `monitoring` warn/audit only. Remove or replace Filebeat hostPath before enforcing Restricted in `elastic-stack`. |
| Default-deny policies and documented app flows | Implemented for `elastiflix`, `infra`, and `elastic-stack`; runtime validation pending | See policy manifests and flow table. `monitoring` still lacks a reviewed default-deny/allow policy set. |
| Namespace isolation | In progress | Labels and namespace-scoped policies are present. Verify bootstrap/Argo ownership and admission behavior in a live local cluster. |
| RBAC | Partially implemented | Filebeat uses read-only cluster-wide metadata access and a projected token; QA role is namespaced. Review whether the QA identity is actually provisioned and minimize cluster-wide permissions further if metadata requirements allow. |
| Persistent volumes | Implemented for Redis, RabbitMQ, and Elasticsearch | Redis/RabbitMQ PVCs and Elasticsearch StatefulSet claim template exist; validate storage classes and restore behavior in target clusters. |
| Redis authentication, health, persistence | Implemented in direct Kubernetes manifests | Secret-backed password, probes, and PVC exist. Helm values are not the deployed source of truth. Metrics exporter/Prometheus integration is pending. |
| RabbitMQ authentication, health, persistence | Implemented in direct Kubernetes manifests | Secret-backed password, probes, and PVC exist. Queue-depth/throughput/consumer-health monitoring is pending. |
| Helm-based Redis/RabbitMQ deployment | Pending | `kubernetes/infra/infra.yaml` currently owns the workloads while `helm/*/values.yaml` is not referenced by Argo. Select and pin compatible chart versions, then migrate without duplicate owners. |
| Elasticsearch/Kibana auth and TLS | Pending before production exposure | Elasticsearch explicitly disables X-Pack security and Kibana has no authentication. They are not published by the AWS app Ingress, but must not be exposed as production services until credentials/TLS and client configuration are implemented and tested. |
| Filebeat EKS/containerd compatibility | Improved; runtime validation pending | Docker-only path removed; verify symlinks, permissions, API access, and delivery on target node images. HostPath prevents Restricted enforcement. |
| Ingress | Partially implemented | Minikube NGINX Ingress exists. AWS ALB Ingress currently has HTTP only; ACM certificate, HTTPS listener, redirect, and health checks remain prerequisites before production use. |
| Secrets ownership | Partially implemented | Local bootstrap creates local Secrets; AWS manifests define ESO ownership. Ensure Sealed Secrets and ESO do not target the same Secret in a given cluster/environment. |
| NetworkPolicy enforcement | Environment prerequisite | Confirm EKS VPC CNI network-policy support is enabled, or use a CNI that enforces policies. |
| Helm chart and Argo Rollouts versions | Runtime review pending | Inspect installed versions before changing chart or traffic-routing integrations. No genuine weighted traffic routing or metric-driven abort is claimed. |

## Validation and limitations

- No Kubernetes cluster tools are installed in this Arena workspace (`kubectl`, `helm`, `kubeconform`, Docker, and Minikube are unavailable). No cluster state, chart rendering, HPA behavior, PDB behavior, or Filebeat runtime behavior has been claimed as tested here.
- The repository CI runs strict kubeconform validation for the application, infra, Elastic Stack, and AWS manifest directories. HPA/PDB schemas should be checked by that gate.
- No AWS operation, Terraform apply, `kubectl apply`, or manual Argo CD sync was performed.

For local Minikube validation, first ensure metrics-server is enabled, then run `kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes`, inspect `kubectl get hpa,pdb -n elastiflix`, generate controlled load, and verify replica changes and disruption budgets. Validate Filebeat logs with `kubectl logs -n elastic-stack ds/filebeat` and check that it reads `/var/log/containers` and delivers to Logstash. Test each expected and denied network path with temporary diagnostic pods before relying on policy enforcement.

## Remaining work before Phase 3 can be called complete

1. Review and validate metrics-server availability and HPA/PDB behavior on Minikube.
2. Add and validate Redis/RabbitMQ metrics and dashboards/alerts; migrate to Helm only after chart compatibility and single ownership are established.
3. Design and test Elasticsearch authentication/TLS with secret ownership shared consistently by backend, Logstash, and Kibana.
4. Review default-deny coverage for the monitoring namespace and add only measured scrape/alert flows.
5. Verify Filebeat on containerd nodes and decide whether to replace hostPath before enforcing Restricted Pod Security there.
6. Configure AWS ALB HTTPS/ACM and validate the EKS NetworkPolicy flows before any AWS rollout.

Phase 3 is **in progress**, not complete, until the pending items are implemented or explicitly accepted as out of scope and the required local runtime validations pass.
