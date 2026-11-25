# Phase 2: Kubernetes manifest hardening

## Scope and guardrails

Phase 1 is merged in PR #4. Phase 2 addresses the Kubernetes hardening debt explicitly tracked in `docker-scans.yml`, `README.md`, and `DEMO.md`: the Kubernetes Checkov scan currently reports findings without blocking CI.

This phase is repository-only. Do not apply manifests, change EKS/Terraform resources, alter AWS account settings, or trigger a GitOps promotion as part of this work. Changes to live Kubernetes manifests must remain in a reviewed PR until the user performs any AWS-side rollout.

## Baseline

A local Checkov 3.4.10 scan of `kubernetes/` produced 104 report-only findings across six workload manifests:

| Manifest | Findings |
| --- | ---: |
| `kubernetes/infra/infra.yaml` | 32 |
| `kubernetes/elastic-stack/logstash.yaml` | 19 |
| `kubernetes/elastic-stack/filebeat.yaml` | 15 |
| `kubernetes/elastic-stack/kibana.yaml` | 15 |
| `kubernetes/elastic-stack/elasticsearch.yaml` | 14 |
| `kubernetes/application/backend/deployment.yaml` | 9 |
| **Total** | **104** |

Most frequent findings are mutable/non-digest image references (7), non-`Always` image pull policies (7), pod and container security context gaps (7 each), missing read-only root filesystems (7), low/default UIDs (7), missing seccomp profiles (7), service-account token automount (7), and missing NetworkPolicy coverage (7). Other findings include missing probes, capabilities/privilege-escalation controls, resource requests/limits, and secrets supplied through environment variables.

## Implementation sequence

1. **Resolve image identity safely.** Use immutable digests for application images from the signed-image publishing workflow and obtain trusted digests for vendor images. Do not invent digests or substitute mutable tags.
2. **Harden per workload with compatibility checks.** Set pod/container security contexts, seccomp, dropped capabilities, and non-root identities where the image supports them. For read-only root filesystems, explicitly mount writable data, temporary, and log paths; verify Elasticsearch, Kibana, Logstash, Redis, and RabbitMQ paths before changing them. Filebeat's host-log access and UID requirements need separate validation.
3. **Add probes and resource bounds.** Use meaningful health checks and right-size CPU/memory requests and limits for each workload.
4. **Design network policy with the cluster dataplane in mind.** Map required ingress/egress among `elastiflix`, `infra`, and `elastic-stack`; verify that EKS network-policy enforcement is actually enabled before relying on NetworkPolicy resources. A default-deny policy without validated allow rules can break production traffic.
5. **Handle secret delivery intentionally.** Evaluate the backend's password environment-variable contract and secret-volume support before changing it; do not silently change application behavior.
6. **Make the gate blocking only after evidence.** Keep Checkov report-only while the above work is incomplete. Remove each justified exception or skip with a precise reason, then switch Kubernetes Checkov to fail the job and verify the complete GitHub Actions suite.

## Exit criteria

- All findings are fixed or individually documented with an owner, reason, and expiry; no blanket suppression.
- `kubeconform` and Checkov pass for the changed manifests; application/container assumptions have targeted tests or validation.
- Kubernetes Checkov becomes a blocking gate only after the findings are addressed.
- No manifest is applied and no AWS/GitOps rollout is initiated by this phase.
