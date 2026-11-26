# ADR 0002: Commit-SHA image tags and reviewed GitOps promotion

- **Status:** Accepted
- **Date:** 2026-11-25
- **Deciders:** Project maintainer

## Context

Kubernetes manifests referenced `:latest` (or floating tags) historically, which makes "what is running in prod?" unanswerable and rollbacks racy. Docker Hub tags are mutable by default.

## Decision

Elastiflix images (`an619/elastiflix-frontend`, `an619/elastiflix-backend`) are published with the full source commit SHA as their tag. CI and GitOps promotion are separate:

- `.github/workflows/docker-push.yml` builds and publishes `…:<sha>` on `push` to `main` after the required checks.
- CI reports those image references but does not edit or push Kubernetes manifests.
- A maintainer proposes the image-tag change in a separately reviewed GitOps change. Argo CD deploys only after that change is merged (ADR-0001).
- A SHA-shaped tag improves traceability, but Docker Hub tag immutability is not enforced. The publish workflow attaches BuildKit SBOM/provenance attestations, signs each pushed digest, and verifies its Cosign certificate identity and OIDC issuer before reporting success.

## Consequences

- ✅ Image references remain traceable to the source commit; signatures are verified against published digests and CI does not directly change desired production state.
- ✅ Manifest promotion receives a separate review and normal CI before Argo CD syncs it.
- ✅ `docker-scans` builds from the same Dockerfile/context and Trivy-gates the image before `docker-push` publishes it (both are required gates in `devsecops.yml`).
- ⚠️ A SHA-shaped tag is not inherently immutable in Docker Hub; digest pinning and registry enforcement remain future hardening.
- ⚠️ Promotion currently requires a maintainer to create and review the image-reference change; no automated PR creator is configured.

## Alternatives considered

- **Semver release tags:** meaningful for libraries, wrong granularity for continuous delivery of an app.
- **`latest`:** rejected outright — non-deterministic deploys, no rollback story.
