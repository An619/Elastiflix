# Phase 4: Argo CD and Argo Rollouts

## Scope and safety

This phase changes repository configuration only. No cluster was queried, no GitOps Application was synced, and no ingress controller or Rollout was deployed from this workspace. Runtime controller versions, actual weighted traffic, AnalysisRuns, and rollback behavior therefore remain unverified.

## Implemented in Git

### Argo CD and GitOps

- `kubernetes/argocd-local-root.yaml` and `kubernetes/argocd-eks-root.yaml` are environment-specific App-of-Apps roots. The bootstrap applies the local root; the Ansible EKS bootstrap registers the EKS root after installing prerequisites.
- Child Applications are organized under `kubernetes/gitops/local` and `kubernetes/gitops/eks`. They target the explicit `main` branch, enable automated sync, self-healing, and pruning, and deploy environment-specific Kustomize paths—except the EKS workload Application, whose sync is deliberately manual until the separately gated AWS Ingress is approved, installed, and healthy. The root owns that manual-sync Application, preventing an existing child from being left outside the App-of-Apps inventory.
- `kubernetes/argocd-project.yaml` defines the `elastiflix` AppProject. It allowlists the repository and monitoring chart, the four workload namespaces, and only the cluster-scoped kinds needed by kube-prometheus-stack and ESO.
- `kubernetes/argocd-rollout-health.yaml` supplies Argo CD health assessment for local static installs; `helm/argocd/values.yaml` preserves the same customization across EKS chart upgrades. Paused/progressing/healthy/degraded states are represented in the application UI.
- The EKS ALB Ingress remains a separate, explicitly gated Application (`kubernetes/argocd-aws-ingress.yaml`). It is not part of the EKS root until approved ACM/DNS inputs are supplied.
- `scripts/phase4-controller-report.sh` performs a read-only image/Class inventory. Local bootstrap and the EKS Ansible bootstrap run it after installing the pinned controllers and before registering the environment root.

The CI workflow still does not edit or sync production GitOps manifests. Image updates remain reviewed Git changes. The Argo CD roots use `main`; merging this feature branch is still a separate review/approval step.

### Progressive delivery

- `kubernetes/application` is now a Kustomize base; environment-specific routing is selected by `kubernetes/environments/minikube` or `kubernetes/environments/eks`. Minikube's frontend and API Ingress resources live inside its overlay so standard Kustomize load restrictions can render the environment without reaching outside the root.
- The frontend Rollout declares stable (`frontend`) and canary (`frontend-canary`) Services. Its steps route 10%, 25%, 50%, then 100% through the environment's traffic router.
- Minikube uses Argo Rollouts' NGINX ingress integration with the frontend-only `app-ingress`; the API host is in a separate `api-ingress` so the generated NGINX canary Ingress cannot accidentally route `/api` to the frontend canary Service.
- EKS uses Argo Rollouts' ALB weighted target-group integration. The AWS Ingress has a stable-only initial action; Rollouts updates it during a canary. The Ingress still requires approved ACM certificate and DNS configuration before it is registered/synced.
- `frontend-canary-health` queries Prometheus for backend request volume and aggregate error ratio. No traffic is a failed measurement; an error ratio above 1% fails analysis. A failed AnalysisRun aborts the canary and returns traffic to stable.
- **Signal limitation:** backend counters are not labeled by frontend release or canary target. This is a whole-service guard, not canary-only attribution; a future improvement should add a validated per-version/request-target signal before making stronger SLO claims.

### Version compatibility evidence

Repository installer pins were inspected without contacting a cluster:

- Argo Rollouts installer: `v1.10.2` in `bootstrap.sh` and `ansible/playbook.yml`. The versioned upstream documentation for this release documents both NGINX and ALB traffic routers.
- Local Argo CD static installer: `v3.6.3`. EKS chart `argo-cd` `10.20.0` declares `appVersion: v3.6.3` in its upstream Chart.yaml; the app version pins are aligned.
- AWS Load Balancer Controller Helm chart: `3.7.0`. Argo Rollouts v1.10.2 ALB documentation requires AWS Load Balancer Controller v1.1.5 or later, so the repository's chart pin is above the documented minimum. This is not evidence of what is installed in an existing EKS cluster.
- Minikube's ingress add-on version is not pinned in the repository and cannot be inspected here. Confirm the installed ingress-nginx image and Argo Rollouts controller image in the target Minikube cluster before syncing the NGINX overlay.

## Validation performed in the workspace

- Backend tests passed (40 tests, including bounded response/error and latency metric coverage); frontend tests passed (13 tests).
- Parsed the Kubernetes YAML files and checked App-of-Apps project/destination constraints. Rollout and AnalysisTemplate spec fields match the upstream Argo Rollouts v1.10.2 CRD schemas.
- Rendered the Minikube, EKS, local GitOps, and EKS GitOps Kustomizations with Kustomize v4.5.4. All four builds succeeded; rendered resource identities were unique, and the Rollout outputs retained the 10/25/50/100 steps with the expected NGINX or ALB traffic router. The EKS root output includes the workload Application with automated sync disabled as the ALB prerequisite gate.
- `ansible-playbook --syntax-check ansible/playbook.yml` passed with Ansible Core 2.18.7. The read-only controller inventory script passed mocked `kubectl` checks for both Minikube and EKS output paths.
- `kubectl`, Helm, Argo CD, and Rollouts runtime commands were not executed.

## Runtime acceptance checklist (operator-run; not executed in this workspace)

1. Confirm installed controller images before enabling the overlay. The bootstrap invokes the read-only report automatically; it can also be run directly:

   ```bash
   scripts/phase4-controller-report.sh minikube
   # after AWS Load Balancer Controller installation:
   scripts/phase4-controller-report.sh eks
   ```

   Compare the reported images with the pins and compatibility notes above. The script confirms the expected Rollouts v1.10.2 image, a non-`latest` ingress-controller image, and the expected IngressClass; it does not prove runtime traffic-routing behavior.

2. On Minikube, inspect the generated canary Ingress and its `canary` / `canary-weight` annotations while advancing through rollout steps. Verify requests actually split, not merely replicas.
3. On EKS, only after ACM and DNS are approved, register `kubernetes/argocd-aws-ingress.yaml` and wait until that Ingress Application is synced/healthy and the ALB listener is ready. Then manually sync the already-registered `elastiflix` Application. Its automated sync remains disabled as an explicit gate; enable automation only through a reviewed configuration change after the router is confirmed healthy. Inspect the ALB action annotation and target-group weights at 10/90, 25/75, 50/50, then stable 100%.
4. In a disposable/non-production namespace, introduce a deliberately unhealthy canary (for example, a test image that fails readiness) and verify the rollout stops, stable service retains traffic, the Rollout becomes degraded/aborted, and Argo CD reports it accurately. Do not use an unreviewed failure image in the production workload.
5. Exercise a Prometheus AnalysisRun with controlled test traffic and a controlled error-rate breach. Confirm a failed measurement aborts, and a healthy analysis promotes. Verify the exact Prometheus service DNS and query results first.
6. Verify `kubectl argo rollouts get rollout frontend -n elastiflix`, `kubectl argo rollouts history`, `kubectl argo rollouts abort`, and `kubectl argo rollouts undo` against the installed CLI/controller versions.

## Remaining risks and checklist

| Item | Status |
|---|---|
| App-of-Apps roots and restricted AppProject manifests | Implemented; not synced |
| Argo CD Rollout health customization | Implemented; controller refresh not runtime-tested |
| Stable/canary services and environment-specific Kustomize overlays | Implemented; four environment/GitOps builds rendered locally with Kustomize v4.5.4 |
| NGINX true weighted routing | Configured; actual Minikube ingress-nginx version and traffic split pending |
| ALB weighted routing | Configured; actual EKS controller version, ACM/DNS, Ingress sync, and target-group weights pending |
| Prometheus automatic abort signal | Configured as aggregate backend guard; AnalysisRun/rollback behavior pending |
| Canary-attributed metrics | Pending; current counters do not identify canary/release traffic |
| Controlled failure and recovery scenario | Pending operator-run validation |

Do not claim production progressive delivery until the controller versions, actual traffic weights, AnalysisRun failure, and stable-service recovery have been demonstrated in the target environment.
