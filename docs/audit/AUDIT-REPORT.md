# Elastiflix — Audit Report

**Audited baseline:** `main` @ `b87015748d6cc14dfa4935e7f15f5ff5c1b7874a`
**Review branch:** `arena/04e9752b-elastiflix` @ `3c5c33b` — 22 commits, 83 files, +5631 / −255
**Pull request:** #34 (open, mergeable, not merged)
**Report date:** 2026-11-27

Every factual claim below is backed by a command that was run against this tree. Where
something could not be verified in this environment, it says so explicitly rather than
implying success.

---

## 1. Executive summary

The repository is in materially better shape than the audited baseline, and the deltas are
verified rather than asserted: Kubernetes findings 104 → 0, tests 51 → 84, and the CI pipeline
is green end to end including the external Sonar gate.

The audit's central conclusion is that **`main` could not be trusted as a record of its own
history**. `main` was force-reverted onto a rewritten history, so pull requests recorded as
MERGED describe files that do not exist. Everything here was therefore verified against the
tree, not against PR status.

Two categories of gap remain, and they are different in kind:

- **Documentation drift** — the README and the architecture diagram described a promotion flow,
  a canary ladder and a backup system that the code does not implement. All corrected.
- **Runtime verification** — nothing in this branch has run against a real cluster or AWS
  account, by instruction. Those claims are enumerated in §7 and are unproven, not proven.

---

## 2. What was audited and how

| Area | Coverage | Method |
| --- | --- | --- |
| Roadmap Phases 1–7 | All seven | File-by-file comparison against `main`; each phase recorded in `docs/audit/phase-matrix.md` |
| Repository layout | Full tree | Path resolution, reference grep before any change |
| CI/CD architecture | All 8 workflows | Parsed `on:` triggers and `jobs.*.uses`; caller/trigger graph built from the files |
| Documented architecture | README, SVG, DEMO, LEARN, ADRs | Every factual claim checked against the manifest or workflow it describes |
| Kubernetes manifests | 37 files, 78 documents | `kubernetes-validate` strict + Checkov 3.4.10 |
| Terraform | 23 files | `python-hcl2` parse (17 modules) + CI `fmt`/`validate` |
| Application behaviour | backend, frontend, data-loader | Unit tests, 84 passing |

### Why PR status was not used as evidence

- `git diff origin/main origin/arena-90ec80bf` reports **146 changed files**, and
  `git diff origin/main...origin/arena-90ec80bf` fails with *"no merge base"* — PR #32's branch
  shares no history with today's `main`.
- PRs #30 and #31 are recorded as **MERGED**, yet their files
  (`hpa.yaml`, `slo-rules.yaml`, `argocd-project.yaml`, elastic-stack NetworkPolicies)
  **do not exist** in the audited tree.
- Only PR #33's contribution (kubeconform `-strict` with pinned schema sources) survived the
  revert. It is preserved and extended here.

---

## 3. Audit of `main` against the seven phases

Status at baseline, with what this branch delivered.

| Phase | Baseline state | Delivered | Evidence |
| --- | --- | --- | --- |
| **1 — CI/CD & supply chain** | Kubeconform strict present (from PR #33). No Checkov gate. CI could commit to `main` | Checkov as a hard gate with a report parser that rejects unreasoned suppressions; publishing made read-only; all actions SHA-pinned | `.github/workflows/*`, `scripts/check-checkov-report.py` |
| **2 — Kubernetes hardening** | No PSA labels, no NetworkPolicies, no HPAs/PDBs, secrets in env vars | Capabilities dropped, non-root, read-only root FS, seccomp; HPA/PDB; default-deny NetworkPolicies; PSP→PSA labels; passwords via mounted files | `kubernetes/**`, `backend/src/secretValue.js` |
| **3 — Terraform & AWS** | ElasticLoadBalancingFullAccess; public EKS endpoint; local state | ALB policy scoped to v2.7.2; EKS API private with opt-in CIDR allowlist; S3+DynamoDB state with versioning/PITR | `terraform/**` |
| **4 — GitOps & progressive delivery** | No AppProject; canary ungated | AppProject scoping; AnalysisTemplate gating each canary step | `kubernetes/argocd-project.yaml`, `kubernetes/application/frontend/analysis-template.yaml` |
| **5 — Observability/SRE** | No ServiceMonitor, no SLO rules, no dashboard | ServiceMonitor, SLO burn-rate rules, Grafana dashboard, offline validator + tests | `kubernetes/monitoring/**`, `scripts/validate-observability.py` |
| **6 — Backup & DR** | Nothing (snapshot tooling existed only on PR #32) | Snapshot client + mocked tests + runbook; SLM daily 02:30 UTC, 30-day retention | `scripts/elasticsearch-snapshot.sh`, `docs/security/phase-6-*.md` |
| **7 — FinOps** | Nothing | Account-wide budget alerts and demo cost guidance | `terraform/finops/**`, `docs/runbooks/phase-7-*.md` |

---

## 4. Repository and CI/CD architecture audit

Full detail in `docs/audit/repository-architecture.md`. Summary of the shape, then the drift.

### 4.1 The pipeline has exactly one entry point

```
push / pull_request → main
└── devsecops.yml                      ← the only event-triggered workflow
    ├── code-tests.yml
    ├── secret-scanning.yml
    ├── dependency-scan.yml
    ├── code-quality.yml
    ├── sonar-scan.yml                 ← requires SONAR_TOKEN
    ├── docker-scans.yml
    └── docker-push.yml                ← needs all six above; main-only
```

Two findings follow directly from this:

1. **A push to any branch other than `main` triggers no CI.** This review branch only gets
   tested because a pull request targeting `main` exists.
2. **Whether the gates are *required* is unverified.** The GitHub API refuses
   branch-protection reads for the available token (`403 Resource not accessible by
   integration`). If `main` is unprotected, the entire pipeline is advisory. This is an
   operator check, not a code change.

### 4.2 Sources of truth

| Question | Source of truth | Notes |
| --- | --- | --- |
| What runs in the cluster | `kubernetes/**` | Apply paths resolved from `spec.source.path` in `argocd-*.yaml` |
| What runs on a laptop | `docker-compose.yml` | Builds the **dev** Dockerfile; CI and the cluster use `Dockerfile.prod`. The two are maintained in parallel |
| What CI enforces | `.github/workflows/*` | — |
| What infrastructure exists | `terraform/**` | — |
| What the bootstrap installs | `ansible/playbook.yml`, `bootstrap.sh` | — |
| What is still unproven | `docs/audit/*`, `docs/security/*` | — |

### 4.3 Documentation drift found

| ID | Finding | Severity | Status |
| --- | --- | --- | --- |
| A1 | README and SVG said CI rewrites `image:` fields and commits back `[skip ci]`. `docker-push.yml` has `contents: read` and cannot commit; it reports the digest for a reviewed change (ADR-0001/0002) | High — describes a removed mechanism | **Corrected** |
| A2 | `kubernetes/aws/` is orphaned: no Application path, no `kubectl apply`, no doc reference. Its ALB Ingress has **no `host:`** and `scheme: internet-facing` | Medium — exposed if wired in as-is | Documented, not changed |
| A3 | `ansible/playbook.yml` pins no chart versions and hard-codes `elastiflix-eks` / `elastiflix-alb-role`; matches Terraform defaults so it works today and fails silently otherwise | Medium | Documented, not changed |
| A4 | Diagram claimed a single 20% canary step; Rollout is 10/25/50/100 with analysis after each | Low | **Corrected** |
| A5 | Diagram and README claimed Velero/MinIO backups; no such manifest, chart or namespace exists | Medium — false assurance | **Corrected** |
| A6 | `.gitleaks.toml` allowlists two `SealedSecret` files by path, which would hide a plaintext Secret added to the same file later | Low — latent | Documented, not changed |
| A7 | Diagram omits HPA/PDB, NetworkPolicies, PSA, AppProject, Checkov gate, SLO rules, backup path | Low | Documented |

**Nothing was moved or renamed.** No path reference anywhere changes as a result of this work.

---

## 5. Defects found and fixed during the work

Five were found by CI — i.e. the pipeline caught real errors that local checks missed — and two
by this audit.

| # | Defect | Found by | Commit |
| --- | --- | --- | --- |
| 1 | Reusable Sonar workflow used `SONAR_TOKEN` without declaring it under `workflow_call.secrets`; pipeline died at start-up | CI | `9750b75` |
| 2 | Checkov gate read `suppress_comment` from the wrong JSON depth (all 30 suppressed checks looked unreasoned); duplicate `aws_caller_identity` | CI | `46463fc` |
| 3 | `terraform/outputs.tf` referenced `cluster_endpoint_public_access`, which `terraform-aws-modules/eks` v20.8.4 does not export | CI | `fe1139d` |
| 4 | `ansible-core==2.11.12` cannot import on the runner's Python 3.12 | CI | `26f1a7e` |
| 5 | Sonar gate: missing container storage limit (wrong rule interpretation on first attempt); new-code coverage at 46% caused by a malformed `sonar.coverage.exclusions` list **and** two untested CI gate scripts | CI | `ca2506d` |
| 6 | README/diagram promotion flow no longer exists (A1), canary weights wrong (A4), Velero claimed but absent (A5), stale `admin123` | This audit | `fd3940b` |

---

## 6. Test and verification results

### 6.1 Automated tests

| Suite | Result |
| --- | --- |
| Backend (`node --test`) | **38 / 38** |
| Frontend (jest) | **13 / 13** |
| Observability validator + Checkov report gate (unittest) | **33 / 33** |
| Elasticsearch snapshot client (mocked API) | pass |
| `bash -n` on all shell scripts | pass |

### 6.2 Static analysis

| Check | Baseline | Now |
| --- | --- | --- |
| Checkov — Kubernetes | 104 failed | **656 passed / 0 failed / 30 skipped** (each skip carries a written reason, enforced by the gate) |
| Checkov — Terraform | ElasticLoadBalancingFullAccess, public EKS endpoint | **52 passed / 0 failed** as CI runs it (`CKV_TF_1` skipped). Unskipped, **5 findings** remain — see §8a |
| `kubernetes-validate --strict` | — | 37 files, 78 documents, **0 errors**, 15 no-local-schema (CRDs, reported by name — never silently skipped) |
| Sonar — new-code coverage | 46.3% (required ≥80%) | **97.3%** |
| Sonar — new-code security rating | C (required A) | **A** |
| Sonar — new vulnerabilities / hotspots / code smells | 1 / — / — | **0 / 0 / 0** |
| GitHub Actions workflows parse | — | 8 / 8 |

### 6.3 CI status on the final commit

Run `45957830804` @ `3c5c33b`: `code-tests`, `checkov-iac-scan`, `trivy-filesystem-scan`,
`trivy-image-scan` (backend + frontend), `npm-audit`, `python-audit`, `hadolint`, `gitleaks`,
`sonar` — all pass. External **SonarCloud Code Analysis: pass**. `docker-push`: skipped by
design (main-only).

---

## 7. What remains unverified

This is the honest boundary of the work. None of the following has been executed, because no
cluster was provisioned and no AWS resources were created.

| Area | Unverified claim | Safe operator check |
| --- | --- | --- |
| Pod Security | `restricted` actually rejects a privileged pod | `kubectl run` a privileged pod in `elastiflix` → expect rejection |
| RBAC | Service accounts cannot exceed their role | `kubectl auth can-i --list --as=system:serviceaccount:…` |
| NetworkPolicy | Default-deny enforced in both directions | `kubectl exec` backend→ES and unrelated-ns→backend → expect timeout |
| Read-only root FS | Containers survive without a writable root | `touch /usr/…` → expect `EROFS` |
| Autoscaling | HPA scales 2→6 at 70% CPU; PDB keeps `minAvailable: 1` | Load loop, watch `kubectl get hpa,pdb` |
| Progressive delivery | Canary aborts on a failed analysis | `kubectl argo rollouts get rollout frontend -w` during a bad revision |
| Observability | Prometheus scrapes `/metrics`; rules evaluate; dashboard renders | `up{job=…}` and `ALERTS{}` in Prometheus |
| Backup / DR | Snapshot creates and restores; RPO 24h / RTO 4h | `scripts/elasticsearch-snapshot.sh`, then restore to a scratch index |
| FinOps | Budget alert delivers | `aws budgets describe-budget` + one SNS test publish |
| Branch protection | Checks are *required*, not advisory | Repo settings (API returned 403) |

Also unverified locally: `actionlint` and `ansible-playbook --syntax-check` (release assets are
blocked from this sandbox); both run in CI and pass. Trivy and Sonar were never run locally.

## 8. Corrections to previously reported figures

One number in the interim summaries sent during this work was wrong and is corrected here.

### 8a. Checkov Terraform: 52/0/0 only with a check skipped

An earlier summary of this work stated Checkov Terraform as "52/0/0" without qualification. That
is only true with `CKV_TF_1` skipped, which is how CI runs it:

```
checkov -d terraform/ --framework terraform --skip-check CKV_TF_1
```

Unskipped, Checkov reports **5 findings, all `CKV_TF_1`** — "ensure Terraform module sources use
a commit hash" — on `vpc`, `eks`, `alb_irsa`, `eso_irsa` and the EBS CSI IRSA role. The CI comment
explains the skip as registry convention:

> CKV_TF_1 is skipped because the registry modules here are already version-pinned, which is the
> registry convention and cannot be expressed as a commit hash.

The last clause is not quite right: registry modules **can** be pinned to a commit with
`?ref=<sha>` on the source URL. The real trade-offs are that it breaks the `version` constraint
and forfeits registry publishing guarantees. So the skip is defensible but the stated reason
overstates it, and five findings are invisible to anyone reading only the CI result. Recorded
here rather than changed, because switching to commit pins changes module provenance and needs a
decision. **Terraform modules are version-pinned, not commit-pinned.**

---

## 9. Accepted limitations (design decisions, not defects)

| Limitation | Rationale |
| --- | --- |
| Image digests not pinned in manifests | CI cannot read the registry on PR runs; the publish job reports digests for a reviewed promotion |
| cosign verified only inside the publishing job | No admission controller in the cluster |
| No admission policy engine (Kyverno etc.) | Deliberate: avoids a new cluster dependency |
| Elasticsearch security disabled | Demo-scope decision, compensated by default-deny NetworkPolicies |
| Alertmanager disabled | No approved notification destination; enabling it would imply paging coverage nobody receives |
| `elastic-stack` namespace audit-only | Filebeat needs `DAC_READ_SEARCH` to read root-owned node logs |
| No resource quotas | Not yet scoped per namespace |
| Argo CD ingress over plain HTTP | Local Minikube convenience |
| No per-canary metric labels | Requires application-level changes |

---

## 10. Commits on this branch (22)

```
3c5c33b ci: retrigger pipeline (no run was created for fd3940b)
fd3940b docs: audit repository and CI/CD architecture against the implementation
1326d31 docs(audit): correct the local-tooling limitations now that promql-parser runs here
ca2506d fix: make the Sonar quality gate pass on its own terms
cdcb266 fix: address the SonarCloud findings raised on this PR
26f1a7e ci: bump ansible-core to a version that supports the runner's Python
fe1139d fix(terraform): stop referencing an output module.eks v20.8.4 does not have
46463fc fix: read Checkov suppression reasons from check_result, drop duplicate data source
9750b75 ci: declare SONAR_TOKEN on the reusable Sonar workflow
6d33497 docs: align README, DEMO, ADRs and CHANGELOG with delivered behaviour
2d5341b docs: record per-phase evidence, gaps and unverified runtime checks
8674881 fix(bootstrap): remove the published Argo CD password and pin what it installs
ab8bbf2 feat(finops): add account-wide budget alerts and demo cost guidance
c300f3a feat(dr): bring the Elasticsearch snapshot client and DR runbook onto main
1b07603 feat(observability): add ServiceMonitor, SLO rules, dashboard and a validator
2c70018 feat(gitops): scope Applications to a project and gate the canary on metrics
0fa49d0 feat(terraform): scope ALB policy, close the EKS API, make state durable
b2a8299 ci: make Kubernetes Checkov a hard gate and stop CI writing to main
419f3a5 feat(k8s): harden workloads, add HPA/PDB, NetworkPolicies and PSA labels
30abe00 feat(backend): read Redis/RabbitMQ passwords from mounted Secret files
b4aeaf7 feat(backend): expose bounded route/status counters and latency histogram
748ca53 docs: record Phase 1-7 audit matrix for current main
```

---

## 11. Recommendation

**Merge-ready with two caveats that need a human:**

1. **Confirm branch protection on `main`** requires the pipeline checks. Without it the gates are
   advisory and this work's value is halved.
2. **Decide on A2/A3/A6** — the orphaned `kubernetes/aws/` directory, the unpinned Ansible
   bootstrap, and the Gitleaks path allowlist. Each is small and each needs a judgement call.

The runtime checks in §7 remain outstanding and cannot be closed from this environment.
