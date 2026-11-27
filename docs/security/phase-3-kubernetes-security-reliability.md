# Phase 3 — Kubernetes security and reliability

## Status on current `main` before this branch

| Control | State | Evidence |
|---|---|---|
| Pod Security Admission | **absent** | no `pod-security.kubernetes.io/*` labels on any Namespace |
| RBAC | present, narrow | `rbac/qa-role.yaml`: get/list/watch on pods and pods/log, bound to a `qa-tester` user |
| ClusterRole for log collection | present, narrow | filebeat: get/list/watch on namespaces, pods, nodes |
| Least-privilege service accounts | **partial** | app pods used the namespace `default` SA with a mounted token |
| Availability controls | **absent** | 2 replicas, no PDB, no HPA |
| Policy engine | **absent** | PSA is the chosen mechanism; nothing was enforcing it |

## What this branch changes

**Pod Security Admission** (`kubernetes/namespaces/namespaces.yaml`):

| Namespace | Mode | Reason |
|---|---|---|
| `elastiflix` | `enforce: restricted` | backend and frontend satisfy restricted (non-root, no privilege escalation, all capabilities dropped, seccomp RuntimeDefault, read-only rootfs) |
| `infra` | `enforce: restricted` | Redis hardened to satisfy restricted; RabbitMQ satisfies everything except read-only rootfs, which restricted does not require |
| `elastic-stack` | audit + warn only | Filebeat needs root and `hostPath` for node logs |
| `monitoring` | audit + warn only | the pod security posture of chart 58.2.2 is owned upstream and unverified here |

Enforcement is a **cluster-side** fact: the labels are declarative, and nothing
in this repository proves a violating pod was ever rejected.

**RBAC:** dedicated `backend` and `frontend` ServiceAccounts with
`automountServiceAccountToken: false`, so the pod cannot call the API even if a
library tries. The `qa-tester` Role/Binding is unchanged and still namespace
scoped; it is a demo of least-privilege access, not an operational account, and
has no authentication mechanism behind it (no OIDC, no client certificate).

**Availability:** HPA 2→6 at 70% CPU and PDB `minAvailable: 1` for both
application workloads, so a node drain cannot take the service to zero.

**Reliability:** startup probes on the slow-booting Elastic workloads so
liveness cannot kill a pod that is merely booting; readiness everywhere;
`progressDeadlineSeconds` on the Rollout; `abortScaleDownDelaySeconds` so a
rolled-back canary is not torn down mid-flight.

## Runtime checks that remain unverified

These need a live cluster and cannot be proven from the repository:

1. **PSA actually rejects.** `kubectl -n elastiflix run probe --image=busybox
   --overrides='{"spec":{"containers":[{"name":"probe","image":"busybox","securityContext":{"privileged":true}}]}}'`
   must be denied. If it is created, the namespace labels were not applied or the
   API server predates PSA (Kubernetes < 1.25).
2. **RBAC denies.** `kubectl auth can-i delete secrets --as=system:serviceaccount:elastiflix:backend -n elastiflix`
   must be `no`.
3. **PDB protects.** `kubectl -n elastiflix drain <node> --dry-run=server` should
   refuse to evict the last available replica.
4. **HPA responds.** Only after metrics-server is installed; without it the HPA
   reports `<unknown>` and does nothing.
5. **Read-only rootfs holds.** Covered in `phase-2-kubernetes-hardening.md`.

## Known gaps not addressed here

- **No admission policy engine.** PSA covers the pod-security baseline; it cannot
  prevent a `:latest` image, a missing resource limit, or an unapproved registry.
  Kyverno/Gatekeeper policies are the natural next step and are deliberately not
  added: an unvalidated policy set that blocks Argo CD syncs is worse than none.
- **`qa-tester` is not a real identity.** It needs OIDC or client certificates
  before it means anything.
- **No audit logging configuration.** EKS audit logs are a Terraform/Terraform-
  module setting (`cluster_enabled_log_types`) and are not enabled; without them
  RBAC and PSA denials leave no trace.
- **Elasticsearch security is disabled** (accepted risk, documented in
  `phase-2-kubernetes-hardening.md`). `phase-6` tooling assumes an authenticated
  endpoint and cannot be used as-is until that changes.
- **No resource quotas or LimitRanges per namespace.** A runaway workload can
  consume the whole node group; without metrics-server and quotas, HPA and
  scheduling are best-effort.
