# Phase 2 — Kubernetes hardening

## What was actually missing

PRs #30 and #31 are recorded as merged and their file lists include
`hpa.yaml`, PDBs, NetworkPolicies, PSA labels and digest-pinned images. None of
those paths existed in the audited tree (`b870157`). Local `checkov` 3.4.10 on
the Kubernetes manifests before this branch: **575 passed, 104 failed,
0 skipped**.

| Requirement | Before | After |
|---|---|---|
| Pod `securityContext` (`runAsNonRoot`, `runAsGroup`, `seccompProfile`) | apps only, partial | all seven workloads |
| Container `securityContext` (`allowPrivilegeEscalation: false`, `drop: ALL`) | apps only | all containers and init containers |
| `automountServiceAccountToken: false` | absent everywhere | every workload except Filebeat, which needs the API |
| Dedicated ServiceAccounts | absent (used `default`) | `backend`, `frontend` |
| Probes | apps only | every workload (startup + readiness + liveness where boot is slow) |
| Resource requests/limits | partial | every container, including Logstash's init container |
| HPA | **absent** | backend + frontend, 2→6 at 70% CPU |
| PodDisruptionBudget | **absent** | backend + frontend, `minAvailable: 1` |
| NetworkPolicy | **absent** | default-deny + explicit allow rules in `elastiflix`, `infra`, `elastic-stack` |
| PSA labels | **absent** | see Phase 3 |
| Secrets via env vars | Redis, RabbitMQ, backend passwords | mounted Secret files |
| Immutable image reference | 40-char SHA tag | unchanged (see below) |

After: **656 passed, 0 failed, 30 skipped** (each skip annotated with a reason).

## Decisions worth reviewing

**Digest pinning is not done.** `CKV_K8S_43`/`CKV_K8S_15` are suppressed with the
reason in the manifest. A commit-SHA tag is immutable in practice for this
repository because only `docker-push` writes it, but a tag can still be
retargeted by anyone with registry write access. Publishing and resolving
digests requires a registry credential the CI does not have
(`docker-push.yml` builds and pushes, but resolution happens at runtime of that
job, after the manifests are already committed). Follow-up: have `docker-push`
print the digest (it now does), then promote `image@sha256:…` in a reviewed
change — the acceptance criterion is that the manifest digest equals the digest
the workflow reports for the same commit.

**`imagePullPolicy: IfNotPresent`** is kept deliberately: the tag is immutable,
so re-pulling on every start only adds registry dependency. `Always` would be
masking a mutable-tag problem this repository does not have.

**RabbitMQ runs without a read-only root filesystem.** It writes generated config
and the Erlang cookie into `/etc/rabbitmq` at start-up. Restricted PSA does not
require a read-only rootfs, so enforcing restricted (see Phase 3) still holds.
The same applies to Elasticsearch/Kibana/Logstash, which write into their home
directories.

**Elasticsearch security is disabled.** `xpack.security.enabled: "false"` with
transport and HTTP TLS off is an accepted risk for a single-node demo cluster
(recorded in the manifest and here). `scripts/prepare-elasticsearch-tls.sh`-
style provisioning was considered and deliberately not ported: enabling TLS
without a certificate authority, rotation and a trusted client bundle would
break the backend and the snapshot client while proving nothing. It stays a
documented prerequisite for any shared environment.

**`ES_API_KEY: ""` remains in the ConfigMap** as an empty placeholder because
`SearchConnector` reads the variable and this branch does not enable ES security.
It must become a Secret reference at the same time security is enabled; it is
called out in `phase-5-sre-observability.md` prerequisites and in the DR
document, both of which depend on an authenticated endpoint.

**Filebeat is the one non-restricted workload.** It reads root-owned node logs
through `hostPath`. `elastic-stack` is therefore audit+warn rather than
enforce, and the exceptions are on the DaemonSet itself.

## Terraform side of Phase 2

| Change | Reason |
|---|---|
| ALB controller policy vendored (`terraform/policies/aws-load-balancer-controller-v2.7.2.json`) | replaced `ElasticLoadBalancingFullAccess`, which grants far more than the controller uses |
| EKS API endpoint private by default | `cluster_endpoint_public_access = true` with no CIDR restriction meant a world-reachable control plane |
| Bastion → control-plane rule | without it, disabling public access would lock the only administrative path out |
| VPC CNI `ENABLE_NETWORK_POLICY=true` | otherwise the NetworkPolicies above are inert |
| EBS CSI driver + IRSA | without it Elasticsearch/Redis/RabbitMQ PVCs stay `Pending` on EKS |
| Subnet ELB discovery tags | the load balancer controller cannot place an ALB without them |
| State bucket versioning/SSE-KMS/public-access block, lock table PITR | state is the only record of what exists |

## SonarCloud findings from the PR (resolved here, or documented)

The project's SonarCloud gate requires security rating A on new code, so each
finding raised by this branch is either fixed or carries an in-code reason:

| Finding | Resolution |
|---|---|
| Path Traversal via command-line argument (`scripts/check-checkov-report.py`) | Fixed: the report path must resolve to an existing non-symlink `.json` file, and invalid JSON is a hard error |
| `npm ci` without `--ignore-scripts` in the audit job | Fixed: audits install with `--ignore-scripts` |
| `[` instead of `[[` in `bootstrap.sh` | Fixed |
| Clear-text URL in `bootstrap.sh` | Documented: the only such URL is the local `http://argocd.local` address printed for the operator |
| Storage limit missing on a container (`backend` pod) | Fixed twice over: every `emptyDir` now has a `sizeLimit`, and both application containers declare an `ephemeral-storage` request/limit (64Mi/512Mi), which is what the rule actually measures |
| Capability assignment (`filebeat`) | Documented: `DAC_READ_SEARCH` is required to read root-owned node logs; all other capabilities are dropped and the pod runs under a dedicated ServiceAccount |

## Coverage of the CI gate scripts

`sonar-project.properties` previously declared `sonar.coverage.exclusions` as
`**/node_modules/**,**/build/**` followed by a *space*, which makes Sonar treat
` **/build/**` as a separate, non-matching entry - so the exclusion list was
effectively one glob deep. It also analysed `scripts/` without ever reporting
coverage for it, which is how two 0%-covered scripts dragged the new-code
coverage gate down. Both are corrected: `scripts` is now a measured source
directory, the Python coverage report is merged from two XML files, and the two
gate scripts are unit-tested (33 tests, 93% statement coverage of
`validate-observability.py`, ~95% of `check-checkov-report.py`).

## Verification performed

- `kubernetes-validate` 1.37 strict against Kubernetes 1.30 schemas (the version
  pinned in Terraform): **78 documents, 0 errors**; 15 CRD documents reported by
  name as having no local schema (Argo Rollouts, Argo CD, ESO, SealedSecret).
- `checkov==3.4.10` (same version as CI): 656 passed / 0 failed / 30 skipped.
- `checkov` Terraform: 52 passed / 0 failed.
- `python-hcl2` parse of all 17 `*.tf` files: 0 failures.
- Backend tests: 38 passing, including the new file-mounted-secret tests.

## Not verified (requires a cluster)

- That the hardened images actually start under `readOnlyRootFilesystem` and
  `runAsNonRoot` with the declared uids. If an image needs a path that is now
  read-only, the pod will `CreateContainerConfigError` or crash-loop on start.
- That HPA scales (needs metrics-server, which this repository does not install).
- That NetworkPolicies deny what they should (needs a CNI that enforces them:
  `ENABLE_NETWORK_POLICY=true` on EKS, `--cni=calico` on Minikube).

## Safe operator checks

```bash
kubectl -n elastiflix rollout status deploy/backend
kubectl -n elastiflix get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[*].securityContext.readOnlyRootFilesystem}{"\n"}{end}'
kubectl auth can-i --list --as=system:serviceaccount:elastiflix:backend   # expect no API verbs
kubectl -n elastiflix get events --field-selector reason=FailedCreate
kubectl -n elastiflix exec deploy/backend -- node -e 'require("fs").writeFileSync("/tmp/probe","x")'   # read-only rootfs proof
kubectl -n elastiflix get hpa
kubectl -n elastiflix get pdb
```

If a pod cannot write to a path it needs, add an `emptyDir` mount for that exact
path rather than removing the read-only root filesystem.
