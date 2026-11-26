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
- Apply the namespace/Pod Security Admission manifests before workloads in both the local bootstrap and the EKS Ansible path.
- Removed static Argo CD admin-password/server-insecure settings, replaced the public HTTP Argo CD Ingress with TLS port-forward access, and pinned local Argo CD/Rollouts and Falco versions.
- Require unique, high-entropy Redis/RabbitMQ passwords for Minikube and Compose. Minikube bootstrap stages credentials in short-lived private files; Compose maps `REDIS_PASSWORD` to a file-backed Compose secret mounted into Redis and the backend, while RabbitMQ requires a supplied password. AWS ExternalSecrets have a dedicated Argo Application/IRSA service account. Local secrets and AWS ESO own distinct environment-specific targets; obsolete cluster-bound SealedSecrets were removed.
- Added ingress default-deny to the monitoring namespace with same-namespace component traffic only. Egress remains unchanged to avoid breaking Prometheus target discovery; no external Ingress peer is allowed.
- Added release-labeled ServiceMonitors for the backend and RabbitMQ Prometheus plugin; backend `/metrics` includes Redis availability/memory/client gauges, bounded HTTP response/status counters, latency histograms, and accurate completed-5xx counts. Grafana dashboards include app and infrastructure metrics, with Prometheus rules for missing targets, backend errors, Redis availability, and RabbitMQ queue depth; Phase 5 adds the proposed SLO recording/alert rules and dashboard. The backend excludes `/metrics` self-scrapes from application counters. Narrow NetworkPolicy rules permit Prometheus to scrape these endpoints. Alertmanager remains disabled, so rules do not deliver notifications.
- Removed Kibana and Grafana Ingress resources; operators access their UIs through local `kubectl port-forward` rather than publishing unauthenticated HTTP dashboards.

## Required network flows

NetworkPolicies are additive: if multiple policies select a pod, the permitted traffic is the union of their allow rules. Confirm the CNI actually enforces NetworkPolicy before relying on these controls.

| Namespace / workload | Direction | Allowed peer | Protocol / port | Purpose |
|---|---|---|---|---|
| `elastiflix` frontend | ingress | ALB subnet CIDRs and ingress-nginx controller | TCP/8080 | Browser traffic to frontend |
| `elastiflix` backend | ingress | ALB subnet CIDRs, ingress-nginx controller, frontend pods | TCP/17700 | API traffic |
| `elastiflix` frontend | egress | backend pods | TCP/17700 | Frontend API proxy |
| `monitoring` Prometheus | ingress/egress | backend metrics endpoint | TCP/17700 | `/metrics` scrape; backend ingress policy permits only Prometheus pods |
| `monitoring` Prometheus | egress | RabbitMQ Prometheus plugin in `infra` | TCP/15692 | RabbitMQ metrics scrape; infra ingress policy permits only Prometheus pods |
| `elastiflix` backend | egress | CoreDNS | UDP/TCP 53 | Service discovery |
| `elastiflix` backend | egress | Elasticsearch in `elastic-stack` | TCP/9200 | Search requests |
| `elastiflix` backend | egress | Redis in `infra` | TCP/6379 | Cache |
| `elastiflix` backend | egress | RabbitMQ in `infra` | TCP/5672 | Search events |
| `infra` Redis | ingress | backend pods in `elastiflix` | TCP/6379 | Cache access |
| `infra` RabbitMQ | ingress | backend pods in `elastiflix` | TCP/5672 | Event publishing |
| `elastic-stack` Elasticsearch | ingress | Kibana, Logstash, backend | TCP/9200 | Search and indexing |
| `elastic-stack` Kibana | ingress | None by NetworkPolicy | — | No Ingress object; use an authorized local port-forward for operator access |
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
| Default-deny policies and documented app flows | Implemented for app, infra, Elastic Stack, and monitoring ingress; runtime validation pending | See policy manifests and flow table. Monitoring egress remains open for Prometheus scrape discovery; confirm CNI enforcement and flows on Minikube. |
| Namespace isolation | Configuration implemented; runtime pending | Namespaces/PSA labels are applied before workloads in local bootstrap and the EKS Ansible path. Verify Argo ownership and admission behavior in a live cluster. |
| RBAC | Partially implemented | Filebeat uses read-only cluster-wide metadata access and a projected token; QA role is namespaced. Review whether the QA identity is actually provisioned and minimize cluster-wide permissions further if metadata requirements allow. |
| Persistent volumes | Implemented for Redis, RabbitMQ, and Elasticsearch | Redis/RabbitMQ PVCs and Elasticsearch StatefulSet claim template exist; validate storage classes and restore behavior in target clusters. |
| Redis authentication, health, persistence, metrics | Implemented in Kubernetes and Compose; runtime pending | Kubernetes uses a Secret-backed password, probes, and PVC; the backend exports authenticated Redis availability, memory, and client-count gauges. Compose uses a mounted environment-sourced secret. Helm values are not the deployed source of truth. Validate the INFO gauge and dashboard on a live cluster. |
| RabbitMQ authentication, health, persistence, metrics | Implemented in direct Kubernetes manifests; runtime pending | Secret-backed password, probes, PVC, and Prometheus plugin are configured. Validate the plugin startup, metrics scrape, and dashboards on a live cluster. |
| Backend metrics, dashboard, alert rules | Implemented; runtime pending | Prometheus scrapes `/metrics`, Grafana dashboard and PrometheusRule exist. Alertmanager is disabled; no notification delivery is configured. |
| Helm-based Redis/RabbitMQ deployment | Pending | `kubernetes/infra/infra.yaml` currently owns the workloads while `helm/*/values.yaml` is not referenced by Argo. Select and pin compatible chart versions, then migrate without duplicate owners. |
| Elasticsearch/Kibana auth and TLS | Implemented in manifests/scripts; runtime validation pending and **blocking before production exposure** | Elasticsearch HTTP/transport TLS, authenticated probes, Kibana `kibana_system`, and separate least-privilege backend/Logstash API keys are configured. `scripts/prepare-elasticsearch-tls.sh` and `scripts/configure-elasticsearch-security.sh` prepare local credentials; `bootstrap.sh` wires these into the local Minikube path. AWS ESO expects approved Secrets Manager payloads. Validate against the pinned Elastic 9.1 images and supported Logstash plugin options before production use. |
| Filebeat EKS/containerd compatibility | Improved; runtime validation pending | Docker-only path removed; verify symlinks, permissions, API access, and delivery on target node images. HostPath prevents Restricted enforcement. |
| Ingress | Local app plus optional public demo endpoint | Minikube app Ingress is HTTP-only for local use. AWS ALB Ingress is configured as internet-facing HTTP with an AWS-generated hostname; no custom/private DNS or ACM certificate is required. This is unencrypted and demo-only; approve public exposure before registering it. Argo CD, Kibana, and Grafana are not published by Ingress. |
| Secrets ownership | Code paths separated; runtime validation pending | Local bootstrap creates Secrets from required environment values; AWS ESO syncs from Secrets Manager with a dedicated IRSA role. Local does not create the AWS ESO Application. Verify actual role trust, secret payload names, and sync status in each environment. |
| NetworkPolicy enforcement | Environment prerequisite | Confirm EKS VPC CNI network-policy support is enabled, or use a CNI that enforces policies. |
| Helm chart and Argo Rollouts versions | Install sources pinned; runtime review pending | Local Argo CD/Rollouts and Falco installers, plus EKS Argo CD/ESO/ALB charts and Rollouts manifest, are version-pinned. Phase 4 now configures real NGINX/ALB traffic routers and Prometheus analysis; inspect installed controller versions and validate routing/abort behavior before rollout. |

## Validation and limitations

- Workspace checks passed: backend tests (**42/42**), frontend tests (**13/13**) and production build, shell syntax for `bootstrap.sh`, `start.sh`, and all `scripts/*.sh`, Ansible playbook syntax, Kubernetes YAML parsing, `git diff --check`, a local OpenSSL smoke test covering certificate chain/CA constraints/SAN/EKU/overwrite refusal, and a mocked-curl test of the Elasticsearch security script and private-file permissions. Local Checkov 3.4.10 Kubernetes scan passed (**674 passed, 0 failed, 3 documented skips**); the three `CKV_K8S_35` exceptions are limited to Elastic Stack workloads whose official startup/configuration path currently consumes SecretKeyRef values as environment variables, with migration to a supported file/keystore flow retained as follow-up. Checkov could not fetch its remote guideline mapping because the TLS connection was closed, while its local scan completed.
- `kubectl`, `helm`, Docker, Minikube, and `kubeconform` are unavailable in this Arena workspace. An attempt to fetch kubeconform was blocked by the release-assets TLS connection, so strict schema validation is not claimed locally. The repository CI runs strict kubeconform validation for the application, infra, Elastic Stack, AWS, and monitoring manifest directories. A read-only cluster inventory script is prepared at `scripts/phase3-cluster-report.sh`; operator-run validation steps are in [`phase-3-manual-validation.md`](phase-3-manual-validation.md).
- No cluster state, chart rendering, HPA/PDB behavior, Filebeat runtime behavior, network-policy enforcement, AWS operation, Terraform apply, `kubectl apply`, or manual Argo CD sync was performed.

For local Minikube validation, first ensure metrics-server is enabled, then run `kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes`, inspect `kubectl get hpa,pdb -n elastiflix`, generate controlled load, and verify replica changes and disruption budgets. Validate Filebeat logs with `kubectl logs -n elastic-stack ds/filebeat` and check that it reads `/var/log/containers` and delivers to Logstash. Test each expected and denied network path with temporary diagnostic pods before relying on policy enforcement.

## Remaining work before Phase 3 can be called complete

1. Review and validate metrics-server availability and HPA/PDB behavior on Minikube.
2. Validate Redis/RabbitMQ metrics, queue/cache dashboards, and exporter/plugin behavior on a live cluster. Configure an approved Alertmanager receiver before claiming alert delivery. Migrate direct manifests to Helm only after chart compatibility and single ownership are established.
3. Run the Elasticsearch TLS/auth bootstrap and validate probes, CA trust, API-key privileges, Logstash plugin compatibility, and Kibana login on Minikube. Keep Elasticsearch internal and do not expose it as production until these runtime checks pass.
4. Validate monitoring NetworkPolicy scrape/ingress behavior and CNI support on Minikube.
5. Verify Filebeat on containerd nodes and decide whether to replace hostPath before enforcing Restricted Pod Security there.
6. Before enabling the AWS Ingress, explicitly approve internet-facing HTTP exposure, verify ALB target health, and validate EKS NetworkPolicy flows. For production, replace HTTP with HTTPS and configure an approved ACM certificate and DNS name.

Phase 3 is **in progress**, not complete, until the pending items are implemented or explicitly accepted as out of scope and the required local runtime validations pass.
