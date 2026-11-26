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
- A maintainer proposes image-reference updates through a separate reviewed GitOps change. CI does not edit manifests or credentials. The local and EKS App-of-Apps roots (`kubernetes/argocd-local-root.yaml` and `kubernetes/argocd-eks-root.yaml`) reconcile environment-specific child Applications from `kubernetes/gitops/`; each child uses automated prune and self-heal. Bootstrap installs the root; EKS ingress remains a separate, approval-gated Application because it exposes a public HTTP endpoint (using the ALB-generated DNS name), and the EKS workload Application stays manual-sync until that Ingress is healthy.
- Argo CD targets the explicit `main` branch for application source. The restricted `elastiflix` AppProject allowlists the repository, monitoring chart, target namespaces and required cluster-scoped resource kinds.
- Git rollback = revert the reviewed manifest change. For an in-flight canary, Argo Rollouts aborts a failed AnalysisRun and restores traffic to the stable Service; the Git desired image still requires a reviewed revert or correction.

## Consequences

- ✅ CI holds **zero** cluster credentials; the attack surface of the build pipeline is minimal.
- ✅ Cluster state is auditable from git; drift is auto-corrected (`selfHeal`) or made visible, never silent.
- ✅ Desired state and rollback history are reviewable in Git; local and EKS roots separate application registration from cluster bootstrap.
- ✅ The frontend Rollout uses environment-specific NGINX or AWS ALB weighted routing, stable/canary Services, and Prometheus analysis that fails closed on no traffic or an error ratio above 1%.
- ⚠️ Installed ingress/ALB controller versions, live weighted traffic, AnalysisRun abort behavior, and restore-to-stable behavior still require operator validation. The AnalysisTemplate currently queries aggregate backend counters, not canary-labeled metrics.
- ⚠️ Debugging requires two lenses: git history *and* `argocd app diff`. Teams must learn the Argo CD mental model.
- ⚠️ Secret bootstrapping remains environment-specific: local credentials are supplied at bootstrap; EKS secrets are synced by ESO through IRSA. No plaintext secret values belong in Git.

## Alternatives considered

- **Push with kubeconfig in CI:** rejected — long-lived cluster credential in GitHub secrets, no drift detection.
- **Flux:** functionally equivalent; Argo CD retained because it is already used in this repository and provides an application UI.
