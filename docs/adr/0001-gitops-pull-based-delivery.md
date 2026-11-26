# ADR 0001: Pull-based GitOps delivery with Argo CD

- **Status:** Accepted
- **Date:** 2026-11-25
- **Deciders:** Project maintainer

## Context

The pipeline must land changes in Kubernetes without giving CI permanent cluster credentials, without `kubectl apply` from a workflow, and in a way that any teammate can audit ("what should be running?") by reading one repo. Two models were available:

1. **Push-based CI/CD** — the workflow applies manifests to the cluster (needs a kubeconfig/token in CI secrets).
2. **Pull-based GitOps** — CI never touches the cluster; an in-cluster agent reconciles it to git.

## Decision

**Pull-based GitOps with Argo CD** (option 2). Specifically:

- `docker-push` builds and publishes commit-SHA-tagged images only; it does not modify Kubernetes manifests or push repository changes.
- A maintainer proposes image-reference updates through a separate reviewed GitOps change. Argo CD Applications (see `kubernetes/argocd-app.yaml`, `argocd-infra.yaml`, `argocd-elk.yaml`, `argocd-monitoring.yaml`) sync their configured paths with automated prune/self-heal; the bootstrap applies these Application objects. There is no App-of-Apps root currently.
- Rollback = revert the reviewed manifest change; Argo CD reconciles the affected path back to the previous desired state.

## Consequences

- ✅ CI holds **zero** cluster credentials; the attack surface of the build pipeline is minimal.
- ✅ Cluster state is auditable from git; drift is auto-corrected (`selfHeal`) or made visible, never silent.
- ✅ Desired state and rollback history are reviewable in Git; Argo CD reconciles only the configured Applications.
- ⚠️ The existing Rollout manifest has no real traffic routing or metric-driven analysis yet; those capabilities require separate implementation and testing.
- ⚠️ Debugging requires two lenses: git history *and* `argocd app diff`. Teams must learn the Argo CD mental model.
- ⚠️ Secret bootstrapping remains environment-specific: local credentials are supplied at bootstrap; EKS secrets are synced by ESO through IRSA. No plaintext secret values belong in Git.

## Alternatives considered

- **Push with kubeconfig in CI:** rejected — long-lived cluster credential in GitHub secrets, no drift detection.
- **Flux:** functionally equivalent; Argo CD retained because it is already used in this repository and provides an application UI. The repository does not currently implement an App-of-Apps root.
