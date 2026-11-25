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
- CI gates on every push/PR: **Gitleaks** (secrets), **Trivy** (CRITICAL/HIGH image CVEs), **Checkov** (Terraform hard gate), **SonarCloud** (SAST + Quality Gate), **npm audit / pip-audit** (high+), **Hadolint**
- **All third-party GitHub Actions are SHA-pinned**
- Image tags equal the git commit SHA (immutable provenance)
- Least-privilege RBAC (`kubernetes/application/rbac`), tier-separated namespaces

## Scope notes

This repository is a reference/demo project. Local `docker-compose.yml` runs Elasticsearch with `xpack.security.enabled=false` **by design** (single-node training demo). Never reuse those settings for anything resembling production.
