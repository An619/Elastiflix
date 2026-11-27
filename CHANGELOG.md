# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project follows semver once tagged releases are cut.

## [Unreleased]

### Added

#### Phase 1 — CI/CD and DevSecOps
- Kubernetes Checkov scan is a **hard gate** via `scripts/check-checkov-report.py` (fails on unsuppressed findings, parse errors, or suppressions without a reason)
- `actionlint`, `bash -n` over all scripts, `terraform fmt -check` (was `fmt`, which rewrote files), Ansible `--syntax-check`
- kubeconform now validates all of `kubernetes/`, not three subdirectories; both downloaded tools are pinned and checksum-verified
- SBOM + max-mode provenance on published images, cosign keyless signing and verification
- `.gitlab-ci.yml`: SHA-only tags (no `:latest`), pinned Trivy image, `pip-audit`

#### Phase 2/3 — Kubernetes hardening and security
- Pod/container security contexts on all seven workloads (seccomp `RuntimeDefault`, `runAsGroup`, read-only rootfs, `automountServiceAccountToken: false`)
- Dedicated `backend`/`frontend` ServiceAccounts; startup/readiness/liveness probes on every workload
- HPA (2→6, 70% CPU) and PDB (`minAvailable: 1`) for both application workloads
- default-deny NetworkPolicies with explicit DNS/ingress/egress rules in `elastiflix`, `infra`, `elastic-stack`
- Pod Security Admission: `restricted` enforced on `elastiflix` and `infra`; audit+warn on `elastic-stack` and `monitoring`
- Redis/RabbitMQ/backend passwords moved from environment variables to mounted Secret files (`backend/src/secretValue.js`, allowlist-enforced)
- Terraform: vendored least-privilege ALB controller policy replaces `ElasticLoadBalancingFullAccess`; EKS API private by default with validated opt-in CIDRs; VPC CNI `ENABLE_NETWORK_POLICY=true`; EBS CSI driver with IRSA; subnet ELB tags; state bucket versioning/SSE-KMS/public-access block and lock-table PITR; `cluster_version` and subnet CIDRs are variables

#### Phase 4 — GitOps and progressive delivery
- `AppProject` limiting source repositories, destinations and cluster-scoped kinds
- Applications pinned to the `main` branch instead of `HEAD`, with ownership finalizers and foreground pruning; a `namespaces` Application applies PSA labels first
- `argocd-cm` health/action customisation so a Rollout reports Healthy
- Frontend stable/canary Services and a `frontend-canary-health` AnalysisTemplate (request volume + 5xx ratio) that aborts the canary; steps 10/25/50/100
- `bootstrap.sh`: no published Argo CD password, pinned Argo CD/Rollouts/Sealed Secrets/Falco versions, images built from the checkout, `--cni=calico`, random local passwords

#### Phase 5 — SRE observability
- `elastiflix_http_responses_total{route,status_class}` and `elastiflix_http_request_duration_seconds` histogram with allowlist-bounded labels
- `/metrics` scrapes excluded from request counters; every completed 5xx counted once; `elastiflix_redis_up` gauge
- ServiceMonitor, 10 recording rules and 6 alerts (99.5%/7d burn rates, objective miss, metrics missing, Redis unavailable, p95 latency)
- Grafana SLO dashboard; `docs/runbooks/elastiflix-availability.md`
- `scripts/validate-observability.py` + 8 tests, wired into CI

#### Phase 6 — Backup and disaster recovery
- `scripts/elasticsearch-snapshot.sh` (register, verify, apply-policy, policy-status, snapshot, list, guarded restore) with mocked-HTTP tests, extended with two new refusal cases
- `docs/security/phase-6-backup-disaster-recovery.md` with probe results, proposed RPO/RTO and the full operator procedure

#### Phase 7 — FinOps
- `terraform/finops`: account-wide budget with ACTUAL and FORECASTED email alerts at configurable thresholds
- `docs/runbooks/phase-7-finops-demo-cost-controls.md`: Minikube-first model, session checklist, teardown reality
- Cost-allocation tags on provisioned resources; `terraform/environments/*.tfvars.example` and `*.backend.hcl.example`

### Changed
- `docs/audit/phase-matrix.md` records the Phase 1–7 audit of `main` at `b870157`, including the evidence that merged PRs #30/#31 no longer exist in the tree
- ADR 0001/0002/0003 updated to match the delivered behaviour (no CI write-back, branch pin, analysis-gated canary)
- `.gitignore` excludes `*.tfvars` (except examples), nested Terraform state/plans, and the FinOps local tfvars

### Removed
- The `docker-push` commit-back step and its `contents: write` workflow permission
- `:latest` pushes from the GitLab pipeline

### Added
- Enterprise documentation set: `SECURITY.md`, `CONTRIBUTING.md`, `.github/CODEOWNERS`, this changelog, `DEMO.md` (interview/demo walkthrough)
- README rewrite: 3D hero art, hand-authored 3D-style architecture SVG (`img/elastiflix-architecture.svg`), full tools + use-cases matrix, security highlights, project layout
- `data-loader/test_index_data.py` — 8 unit tests (fakes ES/tqdm; 98% line coverage of the loader)
- Backend test suites: `urlBuilders.test.js`, `infraMocks.test.js` (mocked Redis/RabbitMQ via `node:test` module mocks), `corsLocal.test.js` — backend coverage 333/452 → 424/455 lines
- Frontend test suite: `components.test.js` — 13/13 tests pass
- SonarCloud Quality Gate now enforced on new code (≥ 80% coverage, 0 blocking issues, 0% duplication)
- Frontend dev Dockerfile lint added to CI (hadolint)

### Changed
- All GitHub Actions pinned to immutable commit SHAs; pins serving Node 20 bumped to Node 24 runtimes (gitleaks-action v3.0.0, build-push-action v7.4.0, setup-terraform v4.0.1, trivy-action v0.36.0)
- `docker-push` job: conditional on `push` to `main` only; concurrency group added; manifest tag bump now rebases and skips empty commits
- `sonar-project.properties` — `data-loader` included in sources; Python coverage wired via `sonar.python.coverage.reportPaths`
- Checkov: Terraform is a hard gate (only `CKV_TF_1` skipped — registry module convention); Kubernetes report-only pending manifest hardening pass
- Logstash 9.1.0, container runs with explicit data/ConfigMap mounts and resource requests

### Fixed
- `docker/build-push-action` v6 → v7.4.0 retired the transitive `actions/cache@node20` pin (removed post-merge deprecation annotations)
- Redis/RabbitMQ clients in the backend build URLs from `*_HOST`/`*_PASSWORD` with proper percent-encoding; cache key covers the full search state + `queryConfig` (was `searchTerm`-only → wrong cached pages)
- `minio.yaml`: placeholder credentials in a `Secret` instead of inline `minioadmin`; `pgsty/silo` pinned to a dated release tag
- Bastion: private subnet, no public IP, SSM-only access, HTTP/80 egress scoped to Ubuntu APT
- Backend no longer leaks internal error messages in 500 responses; structured JSON logging added throughout
- SonarCloud new-code coverage 47.7% → 83.0%; security rating C → A (0 new issues)

### Security
- Removed cleartext `http://elastiflix.local` CORS origins; dropped download-and-run `npx update-browserslist-db` step from the frontend image build
- `npm audit --omit=dev --audit-level=high` now fails the build (was `|| true`); pip-audit added for the data loader
