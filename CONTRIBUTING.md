# Contributing

Thanks for helping improve Elastiflix! This project doubles as a reference for enterprise-grade delivery, so please keep the bar high.

## Ground rules

- Everything goes through a PR to `main`. Direct pushes are not allowed (branch protection).
- CI must be green: tests, audits, Hadolint, SonarCloud Quality Gate (**≥ 80% coverage on new code**), Trivy, Checkov (Terraform), Gitleaks, kubeconform.
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
cd ../terraform && terraform fmt -recursive && terraform init -backend=false && terraform validate
```

- Add tests for behavior changes (backend: `node --test`; frontend: `@testing-library/react`).
- Update docs in the same PR — `README.md` (tools/flow), `README-ELK.md`, or `FROM-SCRATCH.md` as applicable.
- Keep commits small and well-scoped; write messages as `type(scope): summary` (e.g. `fix(backend): …`, `ci(actions): …`).

## Making changes to pipelines / Terraform / manifests

- Workflows: after editing, run the same commands CI runs (see each `uses: ./.github/workflows/…` for exact steps).
- Terraform: `fmt`, `init -backend=false`, `validate`. Checkov must not regress (`--skip-check CKV_TF_1` only, module registry convention).
- Kubernetes: `kubeconform -strict` must pass for `application/`, `infra/`, `elastic-stack/`.

## Reporting security issues

Do **not** use public issues — see [SECURITY.md](SECURITY.md).

## Code of conduct

Be respectful and constructive. Assume good faith, review generously, and credit creditors.
