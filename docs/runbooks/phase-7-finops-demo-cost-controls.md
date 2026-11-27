# Phase 7 — Demo FinOps and cost controls

## Operating model: Minikube by default, AWS on purpose

Day-to-day iteration belongs on Minikube, which costs nothing beyond electricity.
Use AWS for short, planned integration tests and the live demo, then tear the
environment down. **Nothing in this repository makes a running AWS environment
cheap**: an EKS control plane, managed node group, NAT gateway, bastion, ALB, EBS
volumes and retained logs bill continuously while the application is idle.

Before starting an AWS session: check remaining credit, its expiry date and
eligible services, and current account spend. Keep a reserve — promotional
credits can expire and are not the same as cash.

## What exists in this repository

| Control | State | Where |
|---|---|---|
| Account-wide monthly budget with actual and forecasted email alerts | **Present** (operator-applied; not applied here) | `terraform/finops/` |
| Cost-allocation tags on provisioned resources | **Present** | `Project`, `ManagedBy`, `Environment`, `Terraform` on VPC, EKS, bastion, state resources |
| Single NAT gateway outside production | **Present** | `single_nat_gateway = var.environment != "production"` in `terraform/main.tf` |
| Cluster teardown procedure | **Documented, not automated** | this runbook |
| Auto-stop / scheduled shutdown of EKS or node groups | **Absent** | not implemented |
| Savings Plans / Reserved Instances / Spot | **Not used** | deliberately out of scope |
| Spend caps that stop usage | **Impossible with Budgets** | alerts only |

A budget alert is a notification, not a guardrail. AWS Budgets cannot stop or
throttle spending; only deleting resources does that.

## Applying the budget root (operator, reviewed change)

Static validation, no AWS calls and no remote state:

```bash
terraform fmt -check -recursive terraform/
terraform -chdir=terraform/finops init -backend=false
terraform -chdir=terraform/finops validate
```

Then, with an approved amount and recipient list in an ignored local file:

```bash
cp terraform/finops/demo.tfvars.example terraform/finops/demo.tfvars
# edit demo.tfvars: uncomment and set monthly_budget_amount_usd and
# alert_email_addresses. Keep aws_region = us-east-1.
terraform -chdir=terraform/finops init
terraform -chdir=terraform/finops validate
terraform -chdir=terraform/finops plan -var-file=demo.tfvars -out=finops.tfplan
terraform -chdir=terraform/finops show -no-color finops.tfplan
```

The plan must contain exactly one `aws_budgets_budget` creation — no EKS, EC2,
networking, SQS or Kubernetes resources. Stop on the wrong account, recipients,
amount, or any unexpected action. Apply only after explicit owner approval:

```bash
terraform -chdir=terraform/finops apply finops.tfplan
```

A successful apply proves the budget exists. It does **not** prove email
delivery, and it does not cap spend. Verify delivery in Billing and Cost
Management, and expect notifications to lag real usage.

The budget uses local state (`terraform/finops/terraform.tfstate`). That file can
contain recipient addresses: keep it untracked, back it up securely, and never
commit it. One operator at a time.

## Demo session checklist

**Before**

- [ ] Credit balance, expiry and recent spend checked in Billing.
- [ ] Budget alerts confirmed active **and delivery previously tested**.
- [ ] Session window scheduled; nothing else planned on the account.
- [ ] `terraform plan` reviewed against a known-clean state.

**During**

- [ ] Provision only what the demo needs.
- [ ] Watch spend in Cost Explorer (data lags — a low number is not proof).
- [ ] Do not leave the cluster running between sessions or overnight.

**After**

- [ ] Workloads removed via the reviewed teardown, not by `kubectl delete` alone.
- [ ] Verified gone: EKS cluster, managed node group, NAT gateway, bastion,
      ALB/NLB, EBS volumes and snapshots, Elastic IPs, retained CloudWatch logs,
      S3 snapshot objects and Terraform state objects as appropriate.
- [ ] Final spend recorded against the session.

## What teardown actually requires

Stopping pods frees nothing that bills. In order of cost significance for this
stack: EKS control plane (hourly), EC2 nodes (hourly), NAT gateway (hourly plus
data processing), ALB (hourly plus LCU), EBS volumes (per GB-month retained after
the cluster is gone if the PVCs were not deleted), bastion EC2, CloudWatch Logs
storage, and S3 snapshot/state storage.

`terraform destroy` for the main stack removes the resources Terraform manages.
It does **not** remove: snapshots an operator created, the state bucket itself,
DynamoDB lock table contents, Kubernetes-created EBS volumes that outlived their
PVCs, or the budget. Check the plan before destroying, and re-check the account
afterwards.

Do not run `terraform destroy` against the FinOps root unless the owner has
decided the account should stop receiving budget alerts — destroying it removes
the alerts and changes nothing about spend.

## Prerequisites and permissions

- Account owner approval and access; verify the active identity before any plan.
- AWS Budgets and Cost Explorer permissions; billing-data visibility may require
  account-level settings outside this repository.
- Terraform 1.5 or newer, AWS provider `~> 5.0`.
- An approved monthly threshold and recipient list, stored only in the ignored
  local tfvars file.

## Troubleshooting

| Symptom | Action |
|---|---|
| `missing required variable` | Populate both values in `demo.tfvars`; never add recipients to the example file. |
| Access denied on Budgets/Cost Explorer | Ask the account owner to check billing permissions. Do not broaden IAM blindly. |
| No email arrives | Check recipients, notification subscriptions, thresholds against actual/forecast spend. A new budget does not alert immediately. |
| Plan wants to replace or delete the budget | Stop. Inspect workspace, local state, account, and ownership before touching state. |

## Limits of this phase

- No savings measurement exists. Any future Karpenter/Spot evaluation must use a
  normalized On-Demand baseline from Cost Explorer or CUR, separate compute from
  control plane/NAT/ALB/EBS/logging/data transfer, and account for interruption
  and replacement capacity.
- Karpenter and Spot are **not** implemented. If reconsidered, keep Redis,
  RabbitMQ, Elasticsearch and system/monitoring workloads off Spot until a
  resilience test is approved.
- Budget notifications are advisory. The only real cost control is not leaving
  resources running.
