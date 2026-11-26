# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| `main` (latest) | ✅ |
| Older tags | ❌ — please upgrade |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, report them privately via one of:

- GitHub **Security Advisories** → "Report a vulnerability" on this repository (forking/mirroring? use the equivalent private advisory flow there)

Please include: affected path(s)/component(s), reproduction steps, impact assessment, and any suggested fix. You can expect an acknowledgement within **72 hours** and a remediation plan or fix within **14 days** for critical issues.

We follow coordinated disclosure: after a fix ships, we're happy to credit you (with your permission) in the release notes.

## Security posture (what's already in place)

- Non-root containers, `runAsNonRoot`, `drop: [ALL]` capabilities, no privilege escalation
- No public compute IPs; AWS access via **SSM** to a private bastion
- Secrets in git are **Sealed Secrets** (encrypted); cloud secrets via **External Secrets Operator + AWS Secrets Manager (IRSA)**
- CI is configured for **Gitleaks**, **Trivy** image scanning, **Checkov** (Terraform blocking; Kubernetes currently report-only), **SonarCloud**, dependency audits, and **Hadolint**; required checks must be observed green before calling a change validated
- Workflow permissions default to read-only; publishing receives only the Docker Hub secrets and OIDC signing permission it needs
- Images use commit-SHA tags, and the publish workflow is configured to attach BuildKit/Syft SBOM and provenance attestations and Cosign-sign/verify the pushed digest; SHA tags alone are not registry-enforced immutable
- Frontend full-tree HIGH/CRITICAL audit findings have exact package/version/path exceptions with an expiry and tracking record; new, runtime, changed, or expired findings fail the policy check. Moderate findings remain visible under the configured audit threshold.
- **All third-party GitHub Actions are SHA-pinned**
- Least-privilege RBAC (`kubernetes/application/rbac`), tier-separated namespaces

## Vulnerability exception policy

The exception list is [`security/vulnerability-exceptions.json`](security/vulnerability-exceptions.json); the currently accepted CRA build-toolchain risk and exit criteria are documented in [`security/accepted-risks/cra-build-toolchain.md`](security/accepted-risks/cra-build-toolchain.md). Exceptions must be exact to project, resolved package version, dependency path, scope, and severity; they must be development-only, owned, documented, and expire no later than the policy date. The Node policy checker fails closed on new or changed HIGH/CRITICAL findings, runtime findings, expired exceptions, stale entries, invalid audit output, and registry/network errors. Do not add a blanket ignore or extend an exception without reviewing the affected package and updating its risk record.

## Scope notes

This repository is a reference/demo project. Local `docker-compose.yml` runs Elasticsearch with `xpack.security.enabled=false` **by design** (single-node training demo). Never reuse those settings for anything resembling production.
