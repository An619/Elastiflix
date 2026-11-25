# Phase 2: Kubernetes manifest hardening

## Scope and guardrails

Phase 1 is merged in PR #4. Phase 2 addresses the Kubernetes Checkov debt previously tracked in `docker-scans.yml`, `README.md`, and `DEMO.md`.

This is repository-only work. Do not apply manifests, change EKS/Terraform resources, alter AWS account settings, or trigger a GitOps promotion. Changes to live Kubernetes manifests remain in a reviewed PR until the user performs any AWS-side rollout.

## Baseline and current scan

A local Checkov 3.4.10 scan of `kubernetes/` initially reported **104 findings**. After the current hardening edits, the scan reports **678 passed, 0 failed, 1 skipped, and 0 parsing errors** across 70 resources. The one exception is deliberately temporary and annotated on the backend Deployment:

| Check | Workload | Reason | Owner / expiry | Removal condition |
| --- | --- | --- | --- | --- |
| `CKV_K8S_35` | `kubernetes/application/backend/deployment.yaml` | The currently pinned backend image predates mounted Secret-file support. Keep the existing Secret-backed environment contract until a rebuilt image is available; application source and tests now support `*_PASSWORD_FILE`. | `@An619` / 2027-02-22 | Rebuild and promote the backend image by immutable digest with mounted Secret files; remove the legacy secret env references and this skip. |

The scan is now a CI hard gate for unsuppressed failures and YAML parsing errors; its job summary includes any annotated exceptions. Do not add broad or unowned skips.

## Hardening delivered in this working tree

- Pinned the application and vendor image references to candidate OCI digests resolved by the existing read-only workflow. Re-resolve image references if their tags change; never invent digests.
- Added non-root identities, seccomp `RuntimeDefault`, dropped capabilities, no privilege escalation, and read-only root filesystems to the application, Elastic Stack, Redis, and RabbitMQ workloads. Added explicit writable data/cache/temp/log volumes where those workloads need them.
- Added resource bounds and health probes, including resource bounds for the Logstash catalogue init container.
- Added namespace-scoped NetworkPolicies for `elastiflix`, `infra`, and `elastic-stack`, with DNS and required application flows. Logstash's catalogue bootstrap still needs HTTPS egress. Filebeat's Kubernetes API rule assumes private EKS control-plane ENIs in the Terraform private subnets; confirm the actual endpoint/service translation and CNI enforcement behavior before rollout. Keep CIDRs synchronized with `terraform/main.tf`.
- Disabled automatic service-account token mounting for workloads. Filebeat receives only an explicit projected, short-lived token because its Kubernetes metadata processor requires API access; its read-only RBAC remains scoped to namespaces, pods, and nodes.
- Added backend support for password files restricted to two fixed Secret mount paths, with tests for successful reads, missing files, and rejection of arbitrary paths. Updated Nginx's Kubernetes Service lookup so it no longer uses Docker's `127.0.0.11` resolver.
- Added ephemeral-storage requests and limits to Kibana and Filebeat after SonarCloud flagged missing storage bounds.

## Promotion prerequisites and validation limits

- NetworkPolicies are not effective unless the cluster's CNI enforces them. Confirm EKS VPC CNI network-policy support and validate actual ALB, control-plane, pod, service-DNAT, and DNS addresses before enabling these policies in a live cluster. In particular, Filebeat's API allow rule assumes private control-plane ENIs; a public-only EKS API endpoint will not match the private-subnet CIDRs. The manifest CIDRs mirror the VPC public and private subnets in `terraform/main.tf`; they are not a substitute for live topology validation.
- The current manifest image digests identify existing candidate images, not images built from these uncommitted source edits. Rebuild/publish and re-resolve the frontend/backend digests before promoting their source changes; do not treat a source change as present in an older image.
- The Logstash init container currently downloads the movie catalogue from GitHub. Its NetworkPolicy permits TCP/443 egress; replace that bootstrap with a pre-baked or internally hosted catalogue before narrowing external egress further.
- RabbitMQ/Redis SealedSecrets and AWS ExternalSecrets remain cluster-side prerequisites. Nothing was applied or deployed during this phase.

## Verification performed

- Checkov 3.4.10: **678 passed, 0 failed, 1 documented skip, 0 parsing errors**.
- Backend Node tests: **29 passed, 0 failed**.
- Frontend Jest tests: **13 passed, 0 failed**; production frontend build succeeded.
- Kubernetes YAML parsing and `git diff --check` are run as part of final validation. Hosted GitHub checks still need to run against the updated branch.

## Exit criteria

- Unsuppressed Checkov findings and YAML parse errors fail CI; the only skip above has an owner, reason, expiry, and removal condition.
- Review image digests, network-policy flows, secret availability, and the EKS CNI prerequisite before any promotion.
- Do not apply manifests or initiate an AWS/GitOps rollout as part of this work.
