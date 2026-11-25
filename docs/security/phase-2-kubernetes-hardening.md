# Phase 2: Kubernetes manifest hardening

## Scope and guardrails

Phase 1 is merged in PR #4. Phase 2 hardens the Kubernetes manifests and promotes app images built from the hardened source. No AWS cluster was created or started as part of this work. No `kubectl apply` or manual GitOps sync was performed.

PR #26 merged the workload and policy hardening. Its main-branch pipeline built and published the application images, generated SBOM/provenance, and signed/verified both image digests. PR #27 is the follow-up manifest promotion using those exact digests. A merge does not create/start EKS; if a cluster already exists and Argo CD is connected to these paths, its automated reconciliation may apply merged desired state.

## Baseline and current scan

A local Checkov 3.4.10 scan initially reported **104 findings**. The current manifests report **679 passed, 0 failed, 0 skipped, and 0 parsing errors** across 70 resources. The Kubernetes Checkov scan is a CI hard gate for unsuppressed failures and parsing errors; its job summary enumerates any future annotated exceptions. No Kubernetes Checkov exceptions remain active.

## Hardening delivered

- Pinned frontend and backend deployments to immutable digests from the signed images built on main for commit `2e6b726fa47344510ed5d5c3d97fb0da28d6372b`. Vendor image digests remain pinned as well.
- Applied non-root identities, seccomp `RuntimeDefault`, dropped capabilities, no privilege escalation, and read-only root filesystems to application, Elastic Stack, Redis, and RabbitMQ workloads. Added writable data/cache/temp/log volumes as required.
- Added resource requests/limits and health probes, including ephemeral-storage bounds for Kibana and Filebeat and resource bounds for the Logstash catalogue init container.
- Added namespace-scoped NetworkPolicies for `elastiflix`, `infra`, and `elastic-stack`, with DNS and required application flows.
- Disabled automatic service-account token mounting. Filebeat receives an explicit projected, short-lived token for Kubernetes metadata enrichment; its read-only RBAC is limited to namespaces, pods, and nodes.
- Added backend support for mounted password files at two fixed paths, with tests for file reads, missing files, and rejection of arbitrary paths. The backend Deployment now mounts `backend-secret` and supplies only file paths, not password values, through environment variables.
- Updated Nginx's Kubernetes Service lookup to use the pod's configured DNS rather than Docker's `127.0.0.11` resolver.

## Remaining rollout checks

- NetworkPolicies require CNI enforcement. Before a live rollout, verify EKS VPC CNI network-policy support and validate ALB, control-plane, pod, service-DNAT, and DNS paths against the actual cluster. Filebeat's API rule assumes private EKS control-plane ENIs in Terraform's private subnets; a public-only endpoint will not match those CIDRs. Keep policy CIDRs synchronized with `terraform/main.tf`.
- Logstash downloads its movie catalogue from GitHub during initialization, so its policy allows TCP/443 egress. Replace the bootstrap with a pre-baked or internally hosted catalogue before narrowing external egress further.
- Redis/RabbitMQ SealedSecrets and backend-secret provisioning remain cluster-side prerequisites. The manifests are not a substitute for validating those secrets exist in the target namespaces.

## Verification performed

- Checkov 3.4.10 local scan: **679 passed, 0 failed, 0 skipped, 0 parsing errors**.
- Backend Node tests: **30 passed, 0 failed**.
- Frontend Jest tests: **13 passed, 0 failed**; production build succeeded.
- Hosted checks passed on PRs #26–#28. The #27 post-merge run exposed a digest-resolution ordering issue, fixed in PR #28. The latest main workflow passed after retrying its Cosign job; it published and signed both application images. No AWS cluster or GitOps rollout was initiated by these actions.
- Kubernetes YAML parsing and `git diff --check` passed locally.

## Exit criteria

- Unsuppressed Kubernetes Checkov findings and YAML parsing errors fail CI; no active skips remain.
- Review digest identity, secret availability, NetworkPolicy flows, and the EKS CNI prerequisite before relying on the configuration in a live cluster.
- No AWS/GitOps rollout is initiated by this code change; cluster creation and rollout timing remain under the user's control.
