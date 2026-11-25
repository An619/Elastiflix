# Phase 2: Terraform and AWS security

## Scope and guardrails

This phase addresses Terraform/AWS code and operator guidance only. No AWS CLI read/write, Terraform plan/apply, infrastructure provisioning, cluster creation, or chargeable operation was run in this workspace. AWS deployment remains under the repository owner's control.

## Read-only audit findings

| Severity | Evidence and problem | Why it matters | Disposition / validation | Risk and effort |
|---|---|---|---|---|
| High | `terraform/backend.tf` referenced an S3 bucket and DynamoDB lock table, but no bootstrap root was present; their existence and ownership were unverified. | A fresh environment cannot safely initialize, and competing state ownership can corrupt or duplicate infrastructure. | Added an isolated bootstrap root, secure S3/DynamoDB settings, and environment-specific backend examples. CI validates the root; account existence/import remains owner-side. | Medium; bootstrap may incur storage/request costs and must not duplicate an existing bucket/table. |
| High | `terraform/main.tf` enabled the public EKS API without an explicit CIDR allowlist. | Any internet source could reach the API endpoint and attempt authentication. | Changed to private-only by default; public access now requires valid IPv4 CIDRs no broader than `/16`. Terraform validation/Checkov are required; actual connectivity needs an approved network. | Medium; a private-only API requires a working SSM/bastion or VPN path. |
| High | `terraform/alb.tf` attached AWS `ElasticLoadBalancingFullAccess` to the controller role. | The IRSA role had broader permissions than the controller needs. | Replaced it with the upstream v3.7.0 controller policy and pinned the matching Helm chart. CI Checkov validates Terraform; controller and CRD compatibility still needs a no-deploy review before use. | Medium; IAM policy must be upgraded with the chart as a pair. |
| Medium | `terraform/main.tf` hard-coded Kubernetes 1.30 and AZ letter suffixes. | EKS support changes over time; AZ letters can map differently by account/region, and a dynamically expanding AZ set can alter subnet placement. | Kubernetes version is now an explicit required input; exactly three account/region-specific AZ names must be supplied and are identity-filtered. Verify module/add-on support and AZ availability before planning. | Medium; no version was selected or upgraded. |
| Medium | `ansible/playbook.yml` hard-coded cluster/account details and expressed a pipeline with the `command` module. | Bootstrap could target the wrong cluster, skip IRSA annotation, or fail to pipe the generated ServiceAccount manifest. | Added Terraform outputs, environment assertions, local connection mode, shell `pipefail`, and a pinned chart. Added Ansible syntax validation to CI. | Low/medium; Ansible/cluster runtime is not available here. |
| Medium | The bastion user-data ignored SSM-agent failures and its security group allowed HTTP/80 for package setup. | A broken bastion could look provisioned while being unreachable; unnecessary egress broadened the boundary. | Removed HTTP egress and made SSM service detection/start failures explicit. Terraform validation is in CI; AMI behavior needs owner-side verification. | Low; no instance was created. |

## Implemented in this code increment

- Replaced the hard-coded S3 backend values with partial backend configuration and environment-specific backend examples. Dev and production use distinct S3 object keys.
- Added a separate remote-state bootstrap root that configures S3 public-access blocks, bucket ownership controls, a rotating customer-managed KMS key, versioning, a TLS-only bucket policy, access logging to an existing approved organization bucket, noncurrent-state lifecycle transition, DynamoDB KMS encryption and point-in-time recovery, and `prevent_destroy` safeguards. Backend examples consume the KMS key ARN. It uses local state because it must exist before the main root can initialize.
- The Checkov hard gate remains enabled. Documented exceptions are limited to unused S3 event notifications and unconfigured cross-region replication (which requires an approved DR destination/cost). The bootstrap expects an existing same-account/same-region audit bucket; its delivery policy, retention, encryption, and compliance must be verified by the owner. The state key uses explicit KMS encryption; DynamoDB PITR and S3 noncurrent lifecycle settings are enabled.
- Changed EKS API exposure to private-only by default. Public API access is enabled only when the operator supplies valid, non-worldwide IPv4 CIDRs. Added a cluster security-group rule allowing the private SSM bastion to reach the API.
- Made the Kubernetes version an explicit required input rather than silently selecting a stale version. The operator must confirm EKS, Terraform module, and managed add-on compatibility before setting it.
- Require exactly three account-specific Availability Zone names and identity-filter the AWS data source so new zones cannot silently change subnet placement. Confirm those names and availability in the target account/region before planning. Tag public/private subnets for AWS Load Balancer Controller discovery and associate them with the cluster name.
- Removed the bastion bootstrap's swallowed SSM-agent failures and unnecessary HTTP/80 egress. The instance now fails visibly if the expected SSM agent is not installed/running.
- Replaced the AWS Load Balancer Controller's AWS-managed `ElasticLoadBalancingFullAccess` attachment with the upstream [v3.7.0 policy](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.7.0/docs/install/iam_policy.json). Pinned the Ansible Helm chart to v3.7.0 and pass the actual cluster name and IRSA role ARN through Terraform outputs instead of hard-coding them.
- Fixed Ansible's local Kubernetes service-account creation pipeline to use a shell with `pipefail`, and added required Terraform-output assertions.
- Added CI validation for the separate bootstrap Terraform root and Ansible syntax.

## Cost and deployment boundary

The bootstrap root uses a chargeable S3 state bucket, DynamoDB point-in-time recovery, and a customer-managed KMS key; the approved existing access-log bucket may also incur storage and request charges. The key improves control over state encryption but adds recurring cost versus SSE-S3. Cross-region replication is not configured pending an owner-approved disaster-recovery design and budget. The full stack can also incur EKS control-plane, EC2 node/bastion, NAT gateway, ALB, and EBS costs. Check current AWS pricing for the chosen region and review plans before any apply. No estimated prices are claimed here. The private API default avoids public exposure but requires an approved private administrative path; adding a public CIDR should be limited to a controlled, narrow IPv4 range.

## Verification status

- Terraform formatting, provider initialization, Terraform validation, Checkov, and Ansible syntax are wired into hosted CI. The latest PR/merge run must pass before these changes are considered code-validated.
- This workspace does not have Terraform, AWS CLI, or Ansible installed. No AWS account state was inspected, so existence/ownership of the state bucket and lock table remains unverified.
- A Terraform provider lock file is not currently tracked. The ignore rule has been removed so tooling can generate and commit it; provider artifact hashes were not fabricated.
- No plan or apply has been executed. A successful CI validation does not establish AWS API compatibility, resource availability, or cost.

## Pending before Phase 2 can be called operationally complete

1. Confirm whether the named state bucket/lock table already exist in the intended account; import existing resources into the bootstrap state or use a reviewed owner-managed alternative. Do not create duplicates.
2. Review the generated Terraform plan and current regional cost estimates before any apply.
3. Select and verify an EKS Kubernetes version against current AWS support, the pinned EKS module, and add-on requirements. No version upgrade is presumed by this change.
4. Confirm the private API access path from the administrator's environment (public allowlisted CIDR, VPN, or approved SSM/bastion workflow).
5. Review controller v3.7.0's release notes and CRD requirements against the eventual cluster version before running Ansible; this code does not apply CRDs or install the controller now.
6. Verify state bucket ownership, encryption, versioning, DynamoDB locking, IRSA trust, and controller permissions in the intended AWS account without exposing state or credentials.

Phase 2's code-level remediation is **in progress**. Operational readiness remains pending owner-led account review, cost review, and explicit deployment approval.
