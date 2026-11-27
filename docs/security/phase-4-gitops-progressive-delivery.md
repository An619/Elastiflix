# Phase 4 — GitOps and progressive delivery

## Status on current `main` before this branch

Four Applications, all `project: default`, all `targetRevision: HEAD`, all
`automated: prune + selfHeal` with no guards. The frontend `Rollout` stepped
`20% → 30s pause → 100%` with no AnalysisTemplate, no `stableService`/
`canaryService`, and therefore no automated rollback: the "canary" was a timed
delay. There was no AppProject, no health customisation for `Rollout`, no
namespace Application, and `bootstrap.sh` published a fixed Argo CD admin
password and applied `argocd-ingress.yaml`, exposing the Argo CD UI over plain
HTTP.

## Ownership and sync boundaries after this branch

| Application | Path / chart | Destination | Notes |
|---|---|---|---|
| `namespaces` | `kubernetes/namespaces` | cluster-scoped | applied first; `prune: false` because pruning a Namespace deletes every workload in it |
| `elastiflix` | `kubernetes/application` (recursive) | `elastiflix` | workloads + HPA/PDB + NetworkPolicy + RBAC |
| `infra-databases` | `kubernetes/infra` | `infra` | Redis, RabbitMQ, NetworkPolicy |
| `elastic-stack` | `kubernetes/elastic-stack` | `elastic-stack` | Elasticsearch, Kibana, Logstash, Filebeat, NetworkPolicy |
| `monitoring` | kube-prometheus-stack `58.2.2` | `monitoring` | rule/ServiceMonitor/dashboard selectors added |

All five are in the `elastiflix` AppProject, which whitelists exactly the two
repositories and four namespaces they need, so a mistaken Application cannot
deploy into `kube-system` or pull from an arbitrary chart repository.

`targetRevision` is the branch name `main` instead of `HEAD` (`HEAD` silently
follows whatever the remote default branch becomes). Pinning to a commit would be
stricter but would make GitOps unable to deliver the commit that changes it —
documented rather than pretended.

**Ownership finalizers** are set so deleting an Application deletes its
resources; without them, orphans survive and prune stops being trustworthy.
**`PrunePropagationPolicy=foreground` and `PruneLast=true`** make deletion
ordered instead of abrupt. Self-heal remains enabled: the correct response to
drift is to change Git, not the cluster.

## Progressive delivery

```
setWeight 10 → pause 30s → analysis (volume, 5xx ratio)
setWeight 25 → pause 30s → analysis
setWeight 50 → pause 30s → analysis
setWeight 100
```

- A failed `AnalysisRun` aborts the Rollout: traffic returns to the stable
  Service and the canary ReplicaSet is scaled down after
  `abortScaleDownDelaySeconds`.
- **No `trafficRouting` block.** Weight-based splitting through ingress-nginx or
  the ALB requires an additional controller/plugin and a verified ingress
  configuration. Without it Argo Rollouts performs a *basic* canary: it scales
  stable and canary ReplicaSets to approximate the weight, so percentages are
  approximate, not exact. This is stated instead of implying precise split
  traffic that was never tested.
- The analysis reads `elastiflix_http_responses_total` (request volume and 5xx
  ratio), which this branch's backend exports. It is a **service-level** signal:
  the backend does not label metrics by release, so a canary whose failures are
  masked by stable traffic is not detected. Real per-canary attribution needs a
  `rollouts-pod-template-hash` label in the metrics path.
- Analysis **fails closed**: if Prometheus is unreachable or unscraped, the query
  returns no result and the rollout aborts rather than promoting blind.

## Rollback

```bash
# Stop a bad canary immediately
kubectl argo rollouts abort frontend -n elastiflix
kubectl argo rollouts get rollout frontend -n elastiflix --watch

# Undo a bad promotion
git revert <commit>          # image reference / manifest change
# then watch Argo CD sync; do not kubectl set image (selfHeal will revert it)
```

The backend is a plain Deployment on purpose (ADR-0003): it is stateless and the
canary machinery is only justified where user-visible failure is cheapest to
observe.

## Bootstrap changes

`bootstrap.sh` no longer writes a published bcrypt hash for `admin/admin123`,
no longer installs the moving `stable` branches (Argo CD v3.6.3, Rollouts
v1.10.2, Sealed Secrets v0.27.3, Falco chart 9.2.2 are pinned), starts Minikube
with `--cni=calico` so NetworkPolicies are enforced, builds and loads images from
this checkout under the current commit SHA, and generates random local
Redis/RabbitMQ passwords.

**`kubernetes/argocd-ingress.yaml` is still in the tree and still exposes the
Argo CD UI over HTTP** with `server.insecure=true`. It is applied by
`bootstrap.sh` for local convenience only. Anyone exposing it beyond
`argocd.local` must terminate TLS and put authentication in front of it first.

## Verification performed

- Manifest validity: `kubernetes-validate` strict, 78 documents, 0 errors
  (Argo CD/Rollouts CRDs have no local schema and are reported by name).
- `checkov` Kubernetes: 0 unsuppressed findings — this includes the new
  `argocd-project.yaml`, `argocd-namespaces.yaml`, canary Services and
  AnalysisTemplate.
- `scripts/validate-observability.py` asserts that the monitoring Application's
  `ruleSelector`/`serviceMonitorSelector`/Grafana sidecar label actually match
  the objects in `kubernetes/monitoring`. Without that wiring the rules are
  created and never evaluated.

## Not verified (needs a cluster)

- That a Rollout reaches `Healthy` and Argo CD reports it green with the new
  health customisation.
- That an abort actually returns 100% of traffic to the stable Service.
- That the AnalysisTemplate queries resolve (needs a scraped ServiceMonitor).
- That Argo CD accepts the AppProject for the monitoring chart source.

Safe operator checks: `kubectl -n argocd get app -o wide`, `kubectl -n
elastiflix get analysisrun`, `kubectl argo rollouts list rollouts -A`, and
`kubectl -n argocd get app monitoring -o jsonpath='{.status.sync.status}'`.
