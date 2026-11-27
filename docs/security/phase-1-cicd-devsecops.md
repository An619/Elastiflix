# Phase 1 — CI/CD and DevSecOps

## What survived the revert

PR #33 was merged (merge commit `30703b01…`) and **its content is present** in
the audited `main` (`b870157`): `code-tests.yml` still runs `kubeconform` with
`-strict`, `-summary`, and a pinned CRDs-catalog schema commit. Phase 1 is
therefore not "redo the validation gate" — it is "close what the gate did not
cover".

Verified present before this branch:

| Control | Where | Notes |
|---|---|---|
| Strict Kubernetes validation | `code-tests.yml` | `-strict` against upstream schemas + pinned CRDs catalog |
| Fan-out gating | `devsecops.yml` | `docker-push` needs all six jobs |
| Image scan gate | `docker-scans.yml` | Trivy `exit-code: 1`, `CRITICAL,HIGH`, `ignore-unfixed` |
| Terraform IaC gate | `docker-scans.yml` | Checkov, hard fail, only `CKV_TF_1` skipped |
| Secret scanning | `secret-scanning.yml` | gitleaks, full history |
| Dependency audits | `dependency-scan.yml` | npm (backend + frontend prod tree), pip-audit |
| Dockerfile lint | `code-quality.yml` | hadolint, four Dockerfiles |
| Static analysis | `sonar-scan.yml` | SonarCloud quality gate |

`gh run list` shows run `45944004350` green on exactly this commit.

## Gaps found and closed

| Gap | Evidence | Change |
|---|---|---|
| Kubernetes Checkov was report-only | `--soft-fail`, workflow comment admitted ~105 findings | Hard gate via `scripts/check-checkov-report.py`; manifest work in Phase 2 took findings 104 → 0 |
| CI could write to `main` | `permissions: contents: write` at workflow level; `docker-push` committed a tag bump with `GITHUB_TOKEN`, `persist-credentials: true` | `contents: read` by default, per-job permissions, no push step |
| No image provenance | Publish pushed tags only | `sbom: true`, `provenance: mode=max`, cosign keyless sign + verify |
| `terraform fmt` rewrote files | `terraform fmt -recursive` (no `-check`) | `terraform fmt -check` plus a diff report in the step summary |
| Only three Kubernetes paths validated | `kubernetes/application/ kubernetes/infra/ kubernetes/elastic-stack/` | `kubernetes/` (namespaces, aws overlays, monitoring included) |
| No workflow/shell linting | absent | actionlint (pinned + checksum), `bash -n` over all scripts |
| Unpinned CI tooling | `pip install pip-audit` | `pip-audit==2.10.1`, pinned `promql-parser`/`PyYAML` |
| Legacy GitLab pipeline still pushed `:latest` | `.gitlab-ci.yml` | SHA-only tags, default branch only, pinned Trivy image, pip-audit added |
| No observability validation | absent | `scripts/validate-observability.py` + 8 tests in `code-tests.yml` |

## How the gates fail now

- **Checkov Kubernetes:** the scan writes JSON, then
  `scripts/check-checkov-report.py` fails the job on any unsuppressed finding,
  any manifest parse error, or any suppression without a written reason.
  Suppressions are per-resource `checkov.io/skipN` annotations in the manifest,
  so the justification is reviewable next to the object it applies to.
- **kubeconform:** strict, no `-ignore-missing-schemas`. CRD kinds resolve
  through the pinned CRDs catalog commit; a lookup failure is a failure.
- **Terraform:** `fmt -check` then `init -backend=false` and `validate`.

## Deliberate exceptions and their reasons

Every `checkov.io/skipN` is in the manifest it affects. Current set:

- `CKV_K8S_43`/`CKV_K8S_15` (digest pinning, pull-always): application images are
  pinned to a 40-character commit SHA, which is immutable in practice; resolving
  and publishing digests needs registry credentials this CI does not have.
  Upstream dependency images are pinned to reviewed release tags for the same
  reason. Tracked in `phase-2-kubernetes-hardening.md`.
- `CKV_K8S_40` (high UID): the upstream images hard-code uid 999/1000/101 for
  their unprivileged users. Changing that is an image change.
- `CKV_K8S_22` (read-only root filesystem): Elasticsearch, Kibana, Logstash and
  RabbitMQ write into their home directories at start-up. The application pods,
  Redis and Filebeat do run read-only.
- Filebeat: root, hostPath, token mount and `DAC_READ_SEARCH` are inherent to
  collecting node logs (`CKV_K8S_23`, `CKV_K8S_25`, `CKV_K8S_38`, etc.).

## Known limitations

- Trivy image and filesystem scans and the SonarCloud gate were **not** re-run
  locally: this workspace has no registry access and no Sonar token. CI runs them
  on every push; treat their result as authoritative.
- `terraform validate` was not run locally (no provider downloads). HCL parsing
  and Checkov were run; `.github/workflows/code-tests.yml` runs the real thing.
- The cosign identity in `docker-push.yml` is the reusable-workflow ref on
  `main`. If the workflow path or branch changes, the verification string must
  change with it or downstream admission checks will reject the images.
- Node dependency advisories at `moderate` remain (dev-only `c8` →

  `test-exclude` → `glob`/`minimatch` in the backend; `prismjs` via
  `@elastic/eui` in the frontend production tree). They do not block because the
  gate is `--audit-level=high`; the full list is posted to the job summary.
  Fixing either requires a breaking upgrade, which is a separate reviewed change.
