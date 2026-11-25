# Architecture Decision Records

Why the project is the way it is. Format: lightweight [MADR](https://adr.github.io/madr/).

| # | Decision | Status |
|---|---|---|
| [0001](0001-gitops-pull-based-delivery.md) | Pull-based GitOps with Argo CD (CI never touches the cluster) | Accepted |
| [0002](0002-immutable-image-tags-git-sha.md) | Images tagged with the git commit SHA; manifests self-bumped by CI | Accepted |
| [0003](0003-frontend-canary-rollout-backend-deployment.md) | Frontend → Argo Rollouts canary (20% → 30 s → 100%); backend → plain Deployment | Accepted |
| [0004](0004-optional-fail-open-infra-dependencies.md) | Redis & RabbitMQ are optional, fail-open dependencies | Accepted |
