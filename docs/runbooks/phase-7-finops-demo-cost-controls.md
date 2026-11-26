# Phase 7 — Demo FinOps and cost controls

## Scope and credit-conscious operating model

You have a finite **$200 AWS promotional-credit balance** and want it to last. Use Minikube for day-to-day iteration, then use AWS only for short, planned integration tests or a live interview demonstration when the cloud-specific proof is useful. This repository's AWS stack includes services that can continue billing while the app is idle. No code change or budget notification makes a running EKS environment cost-free.

Before using AWS, check the credit's expiration date, eligible services, current remaining balance, and recent account spend in Billing. Keep a reserve instead of treating all $200 as available for Elastiflix: promotional credits may have restrictions, can expire, and are not themselves a spending cap. Choose a monthly budget alert amount substantially below the remaining credit and consistent with your planned demo window; the amount is intentionally required in local configuration, not guessed or set to $200. A monthly budget resets, so also review cumulative credit consumption and billing directly.

Terraform-managed AWS Budgets email alerts are an early-warning aid, **not a hard spending cap**. They do not stop EC2, EKS, NAT, ALB, EBS, or other billable services, and AWS cost/forecast data and notifications can lag. For a live demo, start resources only for the planned window and tear them down as soon as you're done.

This phase implements only an independently managed, account-level monthly AWS cost budget. It does not deploy EKS, Karpenter, Spot nodes, or other AWS infrastructure. Karpenter remains deferred until the EKS minor is selected and compatibility/cost assumptions can be validated in staging. No dollar savings are claimed.

## What the budget covers

`terraform/finops/` is a separate Terraform root so an account budget can be managed independently from the EKS stack. It uses **local Terraform state** so a user does not have to create extra S3/KMS/DynamoDB backend infrastructure just to manage this budget. It creates one monthly `COST` budget for **total AWS account cost** with actual and forecasted email alerts at each configured percentage (default 25%, 50%, 75%, and 100% for earlier warnings). The budget does not filter by service, tag, or region, so it can include other work in the same AWS account. Prefer a dedicated demo account if the budget should represent only Elastiflix. Tag-based cost filtering is not assumed because cost-allocation tags must be activated and resource tag coverage is not guaranteed.

The required monthly amount and approved recipient list intentionally have no defaults. The tracked `demo.tfvars.example` contains no live recipient and does not set an alert amount. Set those values in a private `demo.tfvars` file; `.gitignore` excludes `*.tfvars`. Terraform's local state may also contain the recipient addresses: keep `terraform.tfstate` private, do not commit or share it, and make a secure backup before changing the budget. Use one operator at a time. The budget provider uses `us-east-1` for the Budgets API; this is independent of the EKS workload region.

Email notifications require the AWS account's Budgets/Cost Explorer access and appropriate IAM permissions. Confirm current AWS pricing and any applicable free-tier allowance before using the service. Validate recipient delivery and any confirmation step in the target account. Forecasts and reported costs can lag usage; notification delivery is not a substitute for checking Billing and Cost Management.

## Prerequisites

- AWS account owner approval and access to the intended account; verify identity and account before any plan/apply.
- A private local working copy of `demo.tfvars`. This root intentionally uses local state to avoid separately billed remote-state infrastructure; secure the resulting state file because it can contain recipient addresses.
- An operator-selected monthly alert amount and approved notification email address(es), stored only in an ignored local tfvars file.
- Terraform 1.5 or newer and AWS provider `~> 5.0`.
- Account permissions for AWS Budgets API management. Billing data visibility and budget administration may require account-level/IAM settings outside this repository.

## Static validation (no AWS calls/resources)

From the repository root:

```bash
terraform fmt -check -recursive terraform/
terraform -chdir=terraform/finops init -backend=false
terraform -chdir=terraform/finops validate
```

**Expected:** formatting is clean and validation prints `Success! The configuration is valid.` The init command downloads provider packages but does not contact a remote state backend or create AWS resources. A local tooling or registry failure is a failed validation, not a pass.

## Configure and review (operator-run; do not apply without approval)

1. Verify the active AWS identity/account and decide whether an account-wide budget is appropriate. If the account is shared, alerts include costs outside Elastiflix.
2. Copy the example into an ignored local file and set a reviewed budget amount and approved email recipient(s):

   ```bash
   cp terraform/finops/demo.tfvars.example terraform/finops/demo.tfvars
   ```

   In `demo.tfvars`, uncomment and replace `monthly_budget_amount_usd` and `alert_email_addresses`. Set the threshold list if the default 25/50/75/100 percentages are not suitable. Keep the AWS provider region at `us-east-1`. Choose an amount based on what you can afford; remember it is only an alert threshold.
3. Initialize using local state, validate, and generate a plan:

   ```bash
   terraform -chdir=terraform/finops init
   terraform -chdir=terraform/finops validate
   terraform -chdir=terraform/finops plan \
     -var-file=demo.tfvars -out=finops.tfplan
   terraform -chdir=terraform/finops show -no-color finops.tfplan
   ```

   **Expected:** the plan contains exactly one `aws_budgets_budget.monthly_account_cost` creation with the approved account-wide limit, actual and forecasted email alerts at every selected threshold, and the dedicated budget name. No EKS, EC2, networking, SQS, or Kubernetes resources should appear. Stop on the wrong account, recipients, amount, or any unexpected resource/action. Review plan outputs privately; never commit the plan, local config, or state file.
4. Only after explicit account-owner approval of the plan, apply the saved plan:

   ```bash
   terraform -chdir=terraform/finops apply finops.tfplan
   ```

   **Expected:** Terraform reports one resource added and no changes/deletions. Confirm the budget in Billing and Cost Management and validate alert delivery. A successful apply alone does not prove email delivery or that the alert threshold is appropriate.

## Demo-cluster lifecycle guidance

- Use Minikube locally for frequent code changes; it does not consume AWS credits. This does not prove AWS readiness, so reserve AWS time for cloud-specific checks and the live interview demo.
- For each AWS session, schedule the shortest practical window, review current account spend and credit eligibility first, and provision only the resources needed for the approved scenario. AWS cost reporting can lag; a low bill at the start of a session is not proof that resources are free.
- After testing, follow the separately approved EKS teardown procedure and verify the resources that remain. Stopping application pods is not sufficient: an EKS control plane, managed node group, NAT gateway, bastion, ALB, EBS volumes/snapshots, load balancer, and retained logs or storage may continue to cost money. Do not leave a cluster running between interview/demo sessions.
- Karpenter/Spot is not part of the current implementation. If reconsidered later, retain reliable On-Demand capacity and keep Redis, RabbitMQ, Elasticsearch, and critical system/monitoring workloads off Spot until a separate resilience test is approved.
- Keep the budget only if the account owner wants ongoing account alerts. Removing the budget also removes the alerts; it does not affect the AWS spend itself.

## Savings measurement and limits

No savings measurement is included. For a later Karpenter evaluation, use AWS Cost Explorer or a Cost and Usage Report with a normalized, comparable On-Demand baseline and equivalent workload duration/traffic. Separate EC2 compute from EKS control plane, NAT, ALB, EBS, logging, and data transfer costs. Spot interruptions and replacement capacity can offset lower instance rates. A budget notification does not throttle or terminate usage.

## Troubleshooting

- **Terraform reports missing variables:** populate both required values in the ignored `demo.tfvars`; do not add personal recipients or account amounts to the example file.
- **Access denied or billing APIs unavailable:** ask the AWS account owner to verify Budgets/Cost Explorer access and IAM billing permissions. Do not broaden permissions blindly.
- **No email arrives:** verify recipient addresses, budget notification subscriptions, account email behavior, and notification threshold against current actual/forecasted spend. An alert will not necessarily fire immediately after creation.
- **Plan wants to replace or delete the budget unexpectedly:** stop and inspect the selected workspace, local state, resource ownership, account, and existing budget before changing state.

## Cleanup

The budget is account-level and intentionally can outlive the demo cluster. If its owner explicitly decides to remove it, review a destroy plan for the FinOps root only, confirm it contains only the intended budget, and then apply that reviewed plan. Do not run destroy against the main EKS stack from this runbook. Retain and securely protect the local Terraform state according to the account owner's policy.
