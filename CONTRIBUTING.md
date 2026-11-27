# Contributing

Thanks for helping improve Elastiflix! This project doubles as a reference for enterprise-grade delivery, so please keep the bar high.

## Ground rules

- Everything goes through a PR to `main`. Direct pushes are not allowed (branch protection).
- CI must be green: tests, audits, Hadolint, SonarCloud Quality Gate (**≥ 80% coverage on new code**), Trivy, Checkov (**Terraform and Kubernetes, both hard gates**), Gitleaks, kubeconform, actionlint, the observability validator, and the snapshot-tooling tests.
- Third-party GitHub Actions must be **pinned to a commit SHA** — never to a tag or branch.
- No secrets in the repo, ever. See [SECURITY.md](SECURITY.md).

## Getting started

```bash
git clone https://github.com/An619/Elastiflix.git && cd Elastiflix

# fastest loop — run the whole stack:
./start.sh

# or hack on one tier:
cd backend  && npm ci && npm run dev
cd ../frontend && npm ci --legacy-peer-deps && npm start
```

## Before you open the PR

```bash
cd backend  && npm ci && npm run test:coverage   # 26+ tests, lcov → sonar
cd ../frontend && npm ci --legacy-peer-deps && CI=true npm test -- --watchAll=false
cd ../data-loader && python3 test_index_data.py
cd ../terraform && terraform fmt -check -recursive && terraform init -backend=false && terraform validate
python3 -m unittest data-loader/test_validate_observability.py   # needs PyYAML + promql-parser
bash scripts/test-elasticsearch-snapshot.sh
```

- Add tests for behavior changes (backend: `node --test`; frontend: `@testing-library/react`).
- Update docs in the same PR — `README.md` (tools/flow), `README-ELK.md`, or `FROM-SCRATCH.md` as applicable.
- Keep commits small and well-scoped; write messages as `type(scope): summary` (e.g. `fix(backend): …`, `ci(actions): …`).

## Making changes to pipelines / Terraform / manifests

- Workflows: after editing, run the same commands CI runs (see each `uses: ./.github/workflows/…` for exact steps).
- Terraform: `fmt -check`, `init -backend=false`, `validate`. Checkov must not regress (`--skip-check CKV_TF_1` only, module registry convention). The state backend is configured per environment with `-backend-config=environments/<env>.backend.hcl`; nothing is hard-coded.
- Kubernetes: `kubeconform -strict` must pass for **all of `kubernetes/`**, with no `-ignore-missing-schemas`.
- Checkov Kubernetes is a hard gate. If a finding is genuinely inapplicable, add a `checkov.io/skipN: <CHECK>=<reason>` annotation to that workload — never `--soft-fail`, never a bare skip. `scripts/check-checkov-report.py` fails the build on an unsuppressed finding or a suppression without a reason.
- Observability: `scripts/validate-observability.py` must pass. PromQL that does not parse, a rule the monitoring Application does not select, or a runbook link that does not resolve all fail the build.
- Manifests that change traffic flow (NetworkPolicy, PSA labels) need the runtime prerequisite stated in the PR: EKS `ENABLE_NETWORK_POLICY=true`, Minikube `--cni=calico`.

## Reporting security issues

Do **not** use public issues — see [SECURITY.md](SECURITY.md).

## Code of conduct

Be respectful and constructive. Assume good faith, review generously, and credit creditors.
