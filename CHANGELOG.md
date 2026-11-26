# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project follows semver once tagged releases are cut.

## [Unreleased]

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
- `docker-push` job: conditional on `push` to `main` only; publishes commit-SHA image tags and reports them without mutating GitOps manifests; manifest promotion now requires a reviewed change
- Workflow token permissions are read-only by default; Docker Hub and SonarCloud secrets are passed explicitly to only the reusable jobs that need them
- Kubeconform failures now fail CI for known schemas; unknown custom-resource schemas are explicitly reported as skipped pending dedicated schema validation
- Terraform formatting is checked with `terraform fmt -check` rather than silently formatting the CI workspace
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
- Replaced the permissive backend `npm audit ... || true` with high-severity gates; frontend production and backend audit gates plus `pip-audit` for the data loader are enabled
- Added an exact, expiring policy for existing CRA development-toolchain HIGH findings; new, changed, runtime, invalid-date, and stale findings fail closed
- Added Trivy filesystem and image scans with blocking fixable CRITICAL/HIGH findings and a report-only pass for all CRITICAL/HIGH findings
- Published images now carry BuildKit SBOM/provenance attestations and are Cosign-signed and verified against their digest and GitHub Actions identity; CI no longer writes GitOps manifests
- Added scheduled Dependabot updates for GitHub Actions, npm, Python, Docker, and Terraform
