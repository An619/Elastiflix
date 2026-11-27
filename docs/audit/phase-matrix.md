# Phase audit matrix — current `main` vs. roadmap Phases 1–7

**Audited baseline:** `main` @ `b87015748d6cc14dfa4935e7f15f5ff5c1b7874a`
("chore: update image tags to 30703b0142e155085ba428b208d97fe54c089562 [skip ci]"), fetched
2026-11-27. `origin/main` and the audited commit are identical.

**Review branch:** `arena/04e9752b-elastiflix`, branched from that commit.

## Why this audit trusts only the tree, not PR status

`main` was force-reverted and re-written as a squashed/orphan history. Evidence:

- `git diff origin/main origin/arena-90ec80bf` reports **146 changed files** and
  `git diff origin/main...origin/arena-90ec80bf` fails with *"no merge base"* — the open
  Phase-6 branch (`arena/90ec80bf-elastiflix`, PR #32, head `f922916`) shares no history
  with today's `main`.
- PRs #30 and #31 are recorded as **MERGED** (2026-11-25) and their file lists include
  `kubernetes/application/{backend,frontend}/hpa.yaml`, `kubernetes/elastic-stack/network-policy.yaml`,
  `kubernetes/monitoring/slo-rules.yaml`, `kubernetes/argocd-project.yaml` — **none of these
  paths exist in the audited tree**. The merged flag therefore proves nothing about content.
- PR #33 is recorded as MERGED (merge commit `30703b01…`); its `code-tests.yml` change
  (kubeconform `-strict`, pinned schema locations) **is** present in the audited tree, so
  Phase 1's validation control survived the revert.
- PR #32 is **OPEN** with `merge_base_sha: null`; it cannot be merged into this history.

## Verification tooling available in this workspace

No `terraform`, `kubeconform`, `checkov` or `kubectl` binaries are installed and outbound
network is restricted to `github.com`/`api.github.com`/`registry.npmjs.org`/`pypi.org`
(GitHub *release asset* downloads and `raw.githubusercontent.com` are blocked). The
following **offline equivalents** were used instead, and every result below states which
tool produced it:

| CI control | Local equivalent used here | Fidelity |
|---|---|---|
| `kubeconform -strict` | `kubernetes-validate` 1.37.0 strict mode against Kubernetes 1.30 schemas (the version pinned in Terraform) | Equivalent for built-in kinds; CRD kinds (Argo Rollouts/Argo CD/ESO/SealedSecret) have no local schema and are reported by name, never silently skipped |
| `terraform fmt`/`validate` | `python-hcl2` parse of all 10 `*.tf` files + `terraform validate` was **not** run | Syntax-level only; provider/argument validation unverified |
| `checkov` (Kubernetes + Terraform) | `checkov==3.4.10` installed from PyPI | Same version as CI |
| `trivy` image/fs scan | none (registries unreachable) | Unverified locally; CI-verified on `main` run `45944004350` |
| `actionlint`, `ansible-playbook --syntax-check`, `promql-parser` | not installed | Unverified locally |

## Matrix

### Phase 1 — CI/CD and DevSecOps

| Item | Status on `main` | Evidence |
|---|---|---|
| kubeconform **strict** | **Present** | `code-tests.yml`: `-strict -summary`, pinned CRDs-catalog schema commit `b50f3fb…` |
| Fan-out gating | **Present** | `devsecops.yml`: `docker-push` `needs:` all six jobs |
| Image scan gate | **Present** | `docker-scans.yml` Trivy `exit-code: "1"`, `CRITICAL,HIGH`, `ignore-unfixed` |
| IaC gate — Terraform | **Present (hard fail)** | `checkov -d terraform/ … --skip-check CKV_TF_1` |
| IaC gate — Kubernetes | **GAP: report-only** | `checkov -d kubernetes/ … --soft-fail`; comment admits ~105 findings |
| Secret scanning | **Present** | gitleaks-action, pinned SHA |
| Dependency audits | **Present** | `npm audit --audit-level=high` (backend, frontend prod tree), `pip-audit` |
| Workflow hardening | **GAP** | `devsecops.yml` has workflow-level `permissions: contents: write`; `docker-push.yml` writes to `main` with `GITHUB_TOKEN`, `persist-credentials: true` |
| Image provenance | **GAP** | no SBOM/provenance/signature on publish |
| Other CI integrity checks | **GAP** | no `actionlint`, no `bash -n` on shell scripts, no `terraform fmt -check` (uses `terraform fmt`, i.e. rewrites), no Ansible syntax check |
| Image reference discipline | **GAP** | manifests use mutable SHA *tags*, not digests; nothing verifies that the pushed image for a commit equals the manifest reference |
| `.gitlab-ci.yml` | **GAP (legacy)** | still pushes `:latest` — contradicts ADR-0002 |
| Live validation | CI run `45944004350` on this exact commit is **green** | `gh run list` |

Proposed work: make the Kubernetes Checkov scan a hard gate with an explicit, justified
exception list; drop `contents: write` (publishing becomes read-only; GitOps promotion is a
reviewed change); add SBOM+provenance and cosign keyless signing/verification; add
actionlint, `bash -n`, `terraform fmt -check`, Ansible syntax check, and a manifest-versus-
published-digest verification step; re-pin the GitLab job to explicit digests/tags without
`:latest`.

### Phase 2 — Kubernetes hardening

| Item | Status on `main` | Evidence |
|---|---|---|
| Immutable references | **Partial** | 40-char SHA tags; no `@sha256:` digests; `imagePullPolicy: IfNotPresent` |
| Pod/container `securityContext` | **Partial** | app pods have `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: ALL`; **missing** `seccompProfile`, `readOnlyRootFilesystem`, `runAsGroup`, and any pod-level context; Elastic Stack and `infra` have none |
| Probes | **Partial** | app probes present; `kibana`, `rabbitmq`, `redis`, `logstash` have none |
| Resources | **Partial** | present for apps; missing CPU requests/limits in places |
| Service account tokens | **GAP** | `automountServiceAccountToken` not set on any workload |
| NetworkPolicies | **GAP: absent** | no `NetworkPolicy` anywhere in the tree (Checkov `CKV2_K8S_6` fails 7/7 pods) |
| HPA / PDB | **GAP: absent** | `hpa.yaml` / PDB files do not exist despite PR #30 "merged" |
| Secret references | **Partial** | backend env `secretKeyRef` (passwords via env), ES `ES_API_KEY: ""` plaintext `ConfigMap` entry; replicas run 2 with no PDB |
| Checkov Kubernetes findings | **104 failing, 0 passing** | local `checkov==3.4.10` run |

Proposed work: pod/container hardening for every workload (`seccompProfile`,
`readOnlyRootFilesystem`, `runAsGroup`, `automountServiceAccountToken: false`), probes and
resources for the Elastic Stack + `infra`, HPA + PDB per workload, restricted-PSA labels,
NetworkPolicies per namespace, and digest-pinned mutable-tag images. Checkov stays a hard
gate with documented exceptions only where a check is genuinely inapplicable (e.g.
Filebeat needs root + hostPath for node logs; that namespace stays audit/warn, not enforce).

### Phase 3 — Kubernetes security and reliability

| Item | Status on `main` | Evidence |
|---|---|---|
| Pod Security Admission | **GAP** | namespaces have no `pod-security.kubernetes.io/*` labels |
| RBAC | **Present** | `rbac/qa-role.yaml` + binding (get/list/watch pods, pods/log); filebeat ClusterRole limited to get/list/watch |
| Least-privilege service accounts | **Partial** | filebeat has a dedicated SA; app pods use `default` with token automount |
| Availability controls | **GAP** | no PDB, no HPA, `replicas: 2` with no disruption budget |
| Policy enforcement prerequisites | **GAP** | no policy engine; PSA is the chosen mechanism and is unset |
| Runtime checks | **Unverified — cluster required** | PSA enforcement, NetworkPolicy effect, RBAC denials |

Proposed work: apply PSA labels (replicas/PSA "restricted" where the workload supports it,
audit/warn with written justification otherwise), dedicated ServiceAccounts for
backend/frontend, and a machine-checkable policy test that asserts the PSA labels and
NetworkPolicy coverage. Runtime enforcement stays unverified and is documented as
operator-run checks.

### Phase 4 — GitOps and progressive delivery

| Item | Status on `main` | Evidence |
|---|---|---|
| Argo CD Applications | **Present** | `argocd-app.yaml`, `-elk`, `-infra`, `-monitoring` (Helm chart `58.2.2`, Alertmanager disabled) |
| Sync boundaries | **GAP** | all four Applications use `project: default`; no `AppProject` restricting source repos/destinations; `targetRevision: HEAD` tracks a moving branch |
| Progressive delivery | **Partial** | frontend `Rollout` canary `20% → 30s → 100%` with **no AnalysisTemplate, no stable/canary Services, no rollback criteria** |
| Health checks | **GAP** | no `argocd-cm` health customization for `Rollout` |
| Rollback safety | **Partial** | `automated.prune + selfHeal` with no sync-window/self-heal guard rails; deploys can't be paused for approval |
| Environment split | **GAP** | one flat `kubernetes/` tree; Minikube and EKS overlays are identical, and `bootstrap.sh` applies `argocd-ingress.yaml` (an Ingress into Argo CD with `server.insecure=true` and a known admin password) |
| Bootstrap hygiene | **GAP** | `bootstrap.sh` sets Argo CD password to `admin123`, installs `stable` manifests (unpinned), installs older code while manifests reference SHA 30703b0…, and applies an unauthenticated Argo CD Ingress |

Proposed work: `AppProject` boundary, pinned `targetRevision`, health customization for
`Rollout`, canary Services + AnalysisTemplate with Prometheus queries that actually exist in
`/metrics`, and bootstrap hardening (no known password, pinned versions, no anonymous Argo CD
Ingress by default). Rollback is validated by design + `kubectl argo rollouts` runbook, not
live.

### Phase 5 — SRE observability

| Item | Status on `main` | Evidence |
|---|---|---|
| App metrics | **GAP** | `/metrics` exposes only 4 process-wide counters with no `status`/`route` labels; no latency histogram; `requestsTotal` counts `/metrics` scrapes itself; `errors` only counts autocomplete failures |
| Prometheus scraping | **GAP** | no `ServiceMonitor`; `kube-prometheus-stack` is deployed but nothing selects the backend |
| Prometheus rules / SLOs | **GAP: absent** | no `PrometheusRule` |
| Dashboards | **GAP: absent** | no Grafana dashboard ConfigMaps |
| Alert delivery | **GAP by design** | `alertmanager.enabled: false` — recorded as a prerequisite, not a bug |
| Validation | **GAP** | nothing parses PromQL before merge |

Proposed work: bounded-cardinality `status_class`/`route` response counters and a latency
histogram in the backend (with tests), `ServiceMonitor`, SLO recording/alerting rules with
explicit 99.5 %/7-day assumptions, Grafana dashboards, and an offline PromQL/dashboard
validator wired into CI. Alert delivery, scraping and SLO accuracy remain **unverified**.

### Phase 6 — Backup and disaster recovery

| Item | Status on `main` | Evidence |
|---|---|---|
| Elasticsearch snapshot/SLM tooling | **GAP: only on PR #32** | `scripts/elasticsearch-snapshot.sh`, `scripts/test-elasticsearch-snapshot.sh` exist only on `origin/arena-90ec80bf`; absent from `main` |
| SLM policy / restore drill docs | **GAP: only on PR #32** | `docs/security/phase-6-backup-disaster-recovery.md` |
| Terraform state protection | **Present** | S3 backend (`encrypt = true`) + `terraform-locks` DynamoDB table; **no** versioning/PITR proven from code |
| Object storage (MinIO) | **Present but demo-only** | `minio.yaml`, placeholder credentials; not a backup target |
| Velero | **Absent** | `README.md` mentions it; no manifests, no `credentials-velero` handling beyond `.gitignore` |
| Restore verification | **Unverified — cluster + AWS required** | no snapshot was ever taken |

Proposed work: bring the PR #32 snapshot client, its mocked-HTTP test, and the DR runbook
onto this branch (reviewed, adapted), add the missing state-bucket durability settings
(versioning + PITR) to Terraform, and state plainly which steps require an approved bucket,
identity and cluster.

### Phase 7 — FinOps

| Item | Status on `main` | Evidence |
|---|---|---|
| Budget alerts | **GAP: only on PR #32** | `terraform/finops/` exists only on the PR branch |
| Cost-control guidance | **GAP** | no demo lifecycle/teardown guidance in-tree |
| Cost-relevant Terraform | **Partial** | `single_nat_gateway` for non-prod (good), but no tags usable for cost allocation, no budget, no guardrails |
| Spend limits | **None by design** | no code can cap AWS spend; only alerts |

Proposed work: bring `terraform/finops` (account-wide AWS Budget with actual+forecast
notifications, local state, no secrets in the example) plus `docs/runbooks/phase-7-finops-demo-cost-controls.md`,
add cost-allocation tags to the main stack, and wire static validation into CI.

## Cross-cutting items found during the audit

- `terraform/alb.tf` grants the ALB controller the AWS-managed
  `ElasticLoadBalancingFullAccess` policy (superset of what the controller needs).
- `terraform/main.tf` sets `cluster_endpoint_public_access = true` with no CIDR restriction
  and a hard-coded `cluster_version = "1.30"`; VPC subnets carry no
  `kubernetes.io/role/elb` tags; the VPC CNI add-on is not configured with
  `ENABLE_NETWORK_POLICY=true`, so the NetworkPolicies added here would not be enforced.
- `terraform/backend.tf` hard-codes bucket `elastiflix-terraform-state-an619` and table
  `terraform-locks`; no bootstrap root, no versioning/PITR for the state bucket.
- `kubernetes/application/configmap.yaml` contains `ES_API_KEY: ""` — an empty placeholder
  that invites a plaintext key later; secret material belongs in a Secret.
- EBS CSI driver / `gp3` StorageClass absent, so Elasticsearch/Redis/RabbitMQ PVCs stay
  `Pending` on EKS.

Each of these is addressed or explicitly deferred with a reason in the per-phase documents
under `docs/security/` and `docs/runbooks/`.
