# ADR 0002: Immutable image tags bound to the git commit SHA

- **Status:** Accepted
- **Date:** 2026-11-25
- **Deciders:** Project maintainer

## Context

Kubernetes manifests referenced `:latest` (or floating tags) historically, which makes "what is running in prod?" unanswerable and rollbacks racy. Docker Hub tags are mutable by default.

## Decision

All Elastiflix images (`an619/elastiflix-frontend`, `an619/elastiflix-backend`) are tagged **exclusively with the full git commit SHA** (`${{ github.sha }}`), and manifests are updated by the pipeline itself:

- `.github/workflows/docker-push.yml` builds and pushes `…:<sha>` on `push` to `main` only.
- The same job runs `sed` over `kubernetes/application/{frontend,backend}/deployment.yaml` (and the Rollout), commits `chore: update image tags to <sha> [skip ci]`, rebases, and pushes.
- Argo CD then delivers the referenced SHA (ADR-0001). Image provenance == git provenance.

## Consequences

- ✅ Every running pod is traceable to an exact commit (`kubectl get pod -o yaml | grep image:`).
- ✅ Rollback is a revert; there is no mutable pointer to reason about.
- ✅ The image that reaches main is pre-vetted: `docker-scans` builds from the same Dockerfile/context and Trivy-gates it before `docker-push` runs (both are required gates in `devsecops.yml`).
- ⚠️ Manifests churn by one line per release; repo hygiene (`[skip ci]`) prevents loop triggers.
- ⚠️ Digest pinning (`@sha256:`) would be stricter; tracked as future hardening (see `DEMO.md` — "What would you improve next?").

## Alternatives considered

- **Semver release tags:** meaningful for libraries, wrong granularity for continuous delivery of an app.
- **`latest`:** rejected outright — non-deterministic deploys, no rollback story.
