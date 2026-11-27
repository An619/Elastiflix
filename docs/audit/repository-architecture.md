# Repository and CI/CD architecture audit

**Audited tree:** `main` @ `b87015748d6cc14dfa4935e7f15f5ff5c1b7874a`, re-verified on the review
branch `arena/04e9752b-elastiflix` at `1326d31`. Every statement below is either a command in
this repository or marked as unverified.

**Scope:** prove that the documented architecture (README, `img/elastiflix-architecture.svg`,
`LEARN.md`, `DEMO.md`, ADRs) matches what the tree and the workflows actually do; identify the
source of truth for each path; and record the drift that this audit found. Documentation is
corrected only where it is wrong or where a phase change made it wrong — no file is moved or
renamed by this audit.

## 1. Method

| Check | How |
| --- | --- |
| Workflow graph | Parse every `.github/workflows/*.yml`; collect `on:` triggers and `jobs.*.uses` |
| Callers and triggers | Classify each workflow as an entry point (GitHub event) or reusable (`workflow_call`) |
| Deployment paths | Resolve every `spec.source.path` in `kubernetes/argocd-*.yaml` and every file reference in `README.md` |
| Documentation claims | Each factual claim in the README/SVG checked against the manifest or workflow it describes |
| References before any move | `grep -rn` for every path before renaming or relocating anything (nothing was moved) |

## 2. Sources of truth

| Question | Source of truth | Everything else is a copy |
| --- | --- | --- |
| What runs in the cluster | `kubernetes/**` | README, SVG, DEMO narrate it |
| What runs on a laptop | `docker-compose.yml` | `start.sh` orchestrates it; `LEARN.md` explains it |
| What CI enforces | `.github/workflows/*.yml` | README §flow, SVG "STEP 1" |
| What infrastructure exists | `terraform/**` | README, `FROM-SCRATCH.md` |
| What the cluster bootstrap installs | `ansible/playbook.yml` + `bootstrap.sh` | README §3, ADRs |
| Why a decision was made | `docs/adr/000{1..4}` | README rationale tables |
| What is still unproven | `docs/audit/phase-matrix.md` + `docs/security/phase-*.md` | — |

Local-development and cluster paths are **not** derived from each other. `docker-compose.yml`
builds from `./frontend` and `./backend` (the dev `Dockerfile`); the cluster and CI use
`Dockerfile.prod`. They are maintained in parallel and must be changed together.

## 3. CI/CD: callers and triggers

One entry point, seven reusable workflows. Nothing else can fire on its own.

```
push / pull_request → main
└── devsecops.yml  (entry point)
    ├── code-tests.yml        code-tests
    ├── secret-scanning.yml   secret-scanning
    ├── dependency-scan.yml   dependency-checks
    ├── code-quality.yml      code-quality
    ├── sonar-scan.yml        sonar-qube       ← needs SONAR_TOKEN (declared in workflow_call)
    ├── docker-scans.yml      docker-checks
    └── docker-push.yml       docker-push      ← needs: all six above
                                                 if: push && ref == refs/heads/main
```

Verified facts:

- **No workflow other than `devsecops.yml` has an event trigger.** A `push` to any branch other
  than `main` runs **no** CI. The review branch in this PR only gets checks because a pull request
  targeting `main` exists.
- `docker-push` is gated twice: the `if:` above, plus no `push` trigger of its own. It ran as
  `skipping` on every PR in this branch's history, which is the correct behaviour.
- `sonar-qube` is skipped for forked PRs (no secrets), so the Sonar gate does not block
  fork contributions. This is deliberate and commented in `devsecops.yml`.
- A reusable workflow that requires a secret **must declare it** under `workflow_call.secrets`.
  Omitting that killed the whole pipeline at start-up in this branch (run `45951398263`) and is
  why `sonar-scan.yml` now declares `SONAR_TOKEN`.
- Job-level `permissions` are read-only; only `docker-push` takes `id-token: write` for cosign.

**Unverified here:** whether `main` is protected, and which checks are *required* rather than
merely reported. The GitHub API refuses branch-protection reads for this token
(`403 Resource not accessible by integration`). If `main` is unprotected, `devsecops.yml`'s
`pull_request` gates are advisory — anyone with write access can push to `main` and merge past
them. This is an operator check, not a code change.

## 4. Delivery paths actually implemented

| Path | Entry | Deploys | Status |
| --- | --- | --- | --- |
| Laptop, all-in-Docker | `./start.sh` | `docker-compose.yml` (9 services, dev Dockerfiles) | Matches docs |
| Laptop, GitOps | `./bootstrap.sh` | minikube + Argo CD + Applications + Sealed Secrets | Matches docs |
| Cluster reconcile | Argo CD | `kubernetes/{application,infra,elastic-stack,monitoring,namespaces}`, automated sync, `prune`, `selfHeal` | Matches docs |
| AWS infrastructure | `terraform apply` | VPC · EKS · IAM/IRSA · ALB policy · private SSM bastion | Matches docs |
| AWS cluster add-ons | `ansible-playbook ansible/playbook.yml` | Argo CD · ESO · ALB controller | See finding **A3** |
| Legacy | `.gitlab-ci.yml` | builds and pushes SHA-tagged images to a GitLab registry | Not referenced by any doc as the active path — legacy, kept for the GitLab variant |

## 5. Findings

Severity is about *whether the documentation misleads an operator*, not about exploitability.

### A1 — The documented promotion flow no longer exists (doc is wrong, high impact)

README §"The flow, end to end" step 3 and the SVG ("Image-tag bump (bot) — `docker-push`
rewrites `image:` fields in `kubernetes/application` · commits back `[skip ci]`") describe CI
committing the new image tag to `main`.

`docker-push.yml` does the opposite, deliberately:

```yaml
# Publishing is a read-only operation on the repository. The previous version
# committed a tag bump back to main with GITHUB_TOKEN, which both bypassed
# review and made the running image a side effect of CI. Promotion is now a
# reviewed GitOps change (ADR-0001, ADR-0002).
permissions:
    contents: read
```

and instead publishes the digest to the job summary for a human to promote. The `[skip ci]`
commit messages in `git log` are vestiges of the old bot. **Documentation corrected to match the
code**; the code is the intended behaviour per ADR-0001/0002.

### A2 — `kubernetes/aws/` is orphaned (dead code, medium)

`kubernetes/aws/{eso.yaml,ingress-aws.yaml}` exist, contain an AWS-only `ClusterSecretStore` and
an ALB `Ingress`, and are referenced by **nothing**: no Argo CD `Application` path, no
`kubectl apply` in `bootstrap.sh` or the playbook, no mention in any doc.

Consequences if it were applied: `ingress-aws.yaml` has **no `host:`**, and with
`scheme: internet-facing` an ALB would answer on its public DNS name for any host — exposing the
application on the internet without the `elastiflix.local` host restriction the local Ingress
uses. `eso.yaml` hard-codes `region: us-east-2` (matching `var.aws_region`'s default, so it is
not a mismatch today, but it is a second place to change).

The EKS path therefore has **no defined ingress or secret-store manifest**. Not fixed in this
audit — see §7.

### A3 — Ansible bootstrap pins nothing and names a cluster it may not be talking to (medium)

`ansible/playbook.yml`:

```yaml
- name: Install Argo CD
  command: helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace
```

- **No `--version`** on any of the three charts. `bootstrap.sh` pins Argo CD `v3.6.3`, Rollouts
  `v1.10.2`, Sealed Secrets `v0.27.3` and Falco `9.2.2`; the EKS path pins nothing, so the
  cluster bootstrap is not reproducible and the two paths can silently diverge.
- `--set clusterName=elastiflix-eks` and `arn:...:role/elastiflix-alb-role` are **literal**. They
  match `terraform`'s defaults (`var.cluster_name = "elastiflix"`, `"${var.cluster_name}-eks"`,
  `"${var.cluster_name}-alb-role"`) but break silently for any non-default `cluster_name`.
  `terraform/alb.tf` documents the policy as "pinned in `ansible/playbook.yml` (v2.7.2)"; the
  policy *is* v2.7.2, the *chart* is unpinned, so the sentence is half true and misleading.

### A4 — The SVG's canary description is stale (doc is wrong, low impact)

SVG: "frontend canary — **20% weight** → pause 30s → 100%". The Rollout is
10% → 25% → 50% → 100%, with an `analysis` step on the `frontend-canary-health` template after
each of the first three. The README and ADR-0003 already describe the real ladder correctly; only
the diagram is wrong.

### A5 — The SVG advertises backups that do not exist (doc is wrong, medium)

SVG: "Velero → MinIO (velero ns)", and README lists `velero` among the namespaces. There is **no
Velero manifest, chart, or namespace** anywhere in the tree; `minio.yaml` is an unrelated
MinIO `Deployment` + `Secret`. `docs/audit/phase-matrix.md` already records this as absent, so
the audit document and the marketing diagram disagree. Backup in the delivered system is the
Elasticsearch snapshot client (`scripts/elasticsearch-snapshot.sh`, Phase 6), not Velero.

### A6 — `.gitleaks.toml` allowlists two live secret files (verify)

```toml
[allowlist]
paths = ["kubernetes/infra/redis-sealedsecret.yaml",
         "kubernetes/infra/rabbitmq-sealedsecret.yaml"]
```

Both are real `SealedSecret` objects with 551/552-byte encrypted blobs, so there is nothing to
leak today. But a path allowlist disables scanning for the whole file: if someone later replaces
a `SealedSecret` with a plain `Secret` in the same file, Gitleaks would not report it. The
`SealedSecret` kind is not scannable secret material, so the allowlist buys little. Recommended:
drop the allowlist and confirm Gitleaks stays green (it was green with these files in history
too). **Not changed in this audit** — it needs a Gitleaks run to confirm, and changing a security
gate's config to prove a security gate is unnecessary is a decision for review.

### A7 — Architecture diagram and prose cover only half the pipeline (gap, low)

The diagram's "STEP 1" is a good picture of `devsecops.yml`, but several delivered phases are
invisible: the HPA/PDB pair, the default-deny NetworkPolicies, Pod Security Admission, the
AppProject scoping, the Checkov hard gate, the SLO rules, and the backup/DR path. An operator
reading only the diagram would not know they exist. Documented in the audit rather than redrawn:
the SVG is hand-authored, and a partial redraw risks introducing new inaccuracies.

## 6. What was corrected

`README.md` and `img/elastiflix-architecture.svg` — see the commit that follows this document:

- delivery flow rewritten to the implemented, reviewed-promotion model (A1), with the digest
  promotion step and the "no CI write access" property stated explicitly;
- the Argo CD `admin`/`admin123` login replaced with the generated-password retrieval command
  (the password stopped being static when `bootstrap.sh` was rewritten to generate it);
- canary ladder corrected to 10/25/50/100 with analysis gates (A4);
- namespaces list corrected to the four that exist (A5, `velero` removed);
- SVG: the "Image-tag bump (bot)" box replaced with "Reviewer promotes digest", canary weights
  corrected, Velero box removed.

Not corrected, and why: A2, A3, A6 need code changes with runtime consequences; A7 needs an SVG
redraw. All four are listed in §7 with the decision each one needs.

## 7. Open decisions

| # | Decision | Cost | Recommendation |
| --- | --- | --- | --- |
| A2 | Delete `kubernetes/aws/`, or wire it into an Argo CD Application with a `host:` and a private `scheme` | small | Wire it in — the EKS path currently has no ingress. Deleting removes the only AWS Ingress definition |
| A3 | Pin the three chart versions and derive the cluster/role names from `terraform output` instead of literals | small | Do it; the EKS path is otherwise not reproducible |
| A6 | Remove the Gitleaks path allowlist | small | Remove; confirm green in the same PR |
| A7 | Redraw the SVG to include hardening and DR | medium | Only when the diagram is next touched for A1/A4/A5 anyway |

None of these is a merge blocker for this branch; A1–A5 documentation drift is corrected, A2, A3,
A6 and A7 are recorded with the reasoning an operator needs.
