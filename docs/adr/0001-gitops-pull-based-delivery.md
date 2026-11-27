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

- `docker-push` only builds/pushes images and bumps `image:` tags in `kubernetes/application/` (committing back with `[skip ci]`).
- Five Applications (`namespaces` first, then application, infra, elastic-stack, monitoring) run inside the `elastiflix` AppProject defined in `kubernetes/argocd-project.yaml`, which limits source repositories, destinations and cluster-scoped kinds.
- Each Application tracks the branch `main` (not `HEAD`), with `automated.prune`, `automated.selfHeal`, `PrunePropagationPolicy=foreground`, `PruneLast=true`, and an ownership finalizer.
- `namespaces` has `prune: false`: pruning a Namespace deletes every workload in it.
- Rollback = `git revert` of the tag-bump commit; Argo CD reconciles the cluster back automatically.

## Consequences

- ✅ CI holds **zero** cluster credentials; the attack surface of the build pipeline is minimal.
- ✅ Cluster state is auditable from git; drift is auto-corrected (`selfHeal`) or made visible, never silent.
- ✅ Declarative rollouts (canary, sync waves) come free from the operator model.
- ⚠️ Debugging requires two lenses: git history *and* `argocd app diff`. Teams must learn the Argo CD mental model.
- ⚠️ Config not representable as manifests (secret bootstrap) still needs an imperative step — handled via Sealed Secrets / ESO instead (see ADR-0002 and `kubernetes/infra/`).

## Alternatives considered

- **Push with kubeconfig in CI:** rejected — long-lived cluster credential in GitHub secrets, no drift detection.
- **Flux:** functionally equivalent; Argo CD chosen for the UI/app-of-apps pattern and existing Helm chart maturity.
