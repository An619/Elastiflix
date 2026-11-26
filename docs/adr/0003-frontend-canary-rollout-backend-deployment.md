# ADR 0003: Frontend on Argo Rollouts canary; backend on a plain Deployment

- **Status:** Accepted, runtime validation pending
- **Date:** 2026-11-24
- **Deciders:** Project maintainer

## Context

Both tiers are stateless and 2-replica, but their blast radii and verification signals differ. The frontend is what users see and where visual/JS regressions appear; the backend is a JSON API whose contract is guarded by CI tests and SonarCloud. The previous frontend Rollout changed replica counts only; with two replicas, a `setWeight: 20` step did **not** route 20% of requests to the canary.

## Decision

- **Frontend** (`kubernetes/application/frontend/deployment.yaml`): use an Argo Rollouts `Rollout` with explicit stable (`frontend`) and canary (`frontend-canary`) Services and traffic weights of 10%, 25%, 50%, then 100%. Each intermediate step pauses and runs `frontend-canary-health`.
- **Minikube** (`kubernetes/environments/minikube`): use the Argo Rollouts NGINX traffic router against a frontend-only `app-ingress` (`ingressClassName: nginx`). The API host is split into `api-ingress` because Rollouts clones the stable Ingress for canary traffic. Inventory the target ingress image before enabling this overlay.
- **EKS** (`kubernetes/environments/eks`): use the Argo Rollouts ALB traffic router and AWS Load Balancer Controller weighted target groups. The `app-ingress` Application remains separately gated until public HTTP exposure is approved; it uses the ALB-generated DNS hostname and needs no custom DNS or ACM certificate. Do not update the EKS application image through a canary until that Ingress is installed and healthy.
- **Analysis:** the Prometheus `AnalysisTemplate` requires observed backend request traffic and aborts if the aggregate backend error ratio exceeds 1%. This is a service-level guard, **not** canary-attributed analysis: backend metrics do not yet carry a release/canary label.
- **Backend:** retain the standard `apps/v1 Deployment` with health probes and 2 replicas; its CI/API safety nets and the existing error-rate guard remain appropriate without introducing a second Rollout control path.

Argo Rollouts is pinned to controller manifest v1.10.2. The EKS playbook pins the AWS Load Balancer Controller chart 3.7.0; Argo Rollouts v1.10.2's ALB integration documentation requires AWS Load Balancer Controller v1.1.5 or newer. These are repository pins, **not** proof of versions currently installed in a user cluster.

## Consequences

- ✅ Traffic weights are enforced by NGINX canary annotations in local Kubernetes and by ALB weighted target groups in EKS; they are no longer inferred from replica ratios.
- ✅ Readiness failures and failed/empty Prometheus analysis stop rollout progression; the controller sends traffic back to the stable Service on abort.
- ✅ Argo CD has a custom Rollout health assessment so the UI can report progressing, paused, healthy, or degraded states.
- ⚠️ Runtime routing behavior and rollback are untested in this workspace. Verify the installed ingress/controller versions and run a controlled failure scenario before treating the setup as production-ready.
- ⚠️ The AnalysisTemplate sees aggregate backend metrics. A canary-specific SLO requires request/error metrics labeled by release or traffic target and a validated scrape path.
- ⚠️ The AWS Ingress remains gated on approval to expose unencrypted HTTP publicly. Production use requires HTTPS, an approved ACM certificate, and a DNS name.

## Alternatives considered

- **Replica-only canary:** rejected as genuine weighted routing. Replica ratios are coarse and do not guarantee request percentages.
- **Single traffic provider across both environments:** rejected because Minikube uses ingress-nginx while EKS uses AWS ALB; each environment needs its controller-native router.
- **Both frontend and backend on Rollouts:** deferred; it adds controller surface without a canary-attributed backend traffic signal today.
