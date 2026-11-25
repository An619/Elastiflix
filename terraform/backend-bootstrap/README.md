# Terraform remote-state bootstrap

This separate root creates the S3 bucket and DynamoDB table used by the main `terraform/` root. It uses **local state** because the remote backend must exist before the main root can initialize. Keep the bootstrap state file private, back it up securely, and never commit it.

## What it creates

- An S3 state bucket with public access blocked, bucket-owner enforced ownership, SSE-S3 encryption, versioning, a TLS-only bucket policy, and `prevent_destroy` protection.
- A DynamoDB `PAY_PER_REQUEST` lock table with server-side encryption and `prevent_destroy` protection.

S3 storage/versioning and DynamoDB requests may incur AWS charges. EKS, NAT gateways, EC2 nodes/bastion, and load balancers are separate and materially larger cost items. No AWS resource was created by this change; do not run `apply` until you have reviewed the plan and costs.

## Bootstrap procedure (operator-run only)

1. Confirm whether the configured state bucket and lock table already exist in the intended AWS account/region. If they exist, do not create duplicates; import them into this bootstrap state or have their current owner manage them.
2. Copy `backend-bootstrap.tfvars.example` to a private local `.tfvars` file, choose an account-owned globally unique bucket name, and keep it out of Git.
3. From the repository root, review a plan, then apply only after explicit cost and change review:

   ```sh
   terraform -chdir=terraform/backend-bootstrap init
   terraform -chdir=terraform/backend-bootstrap plan -var-file=backend-bootstrap.tfvars
   terraform -chdir=terraform/backend-bootstrap apply -var-file=backend-bootstrap.tfvars
   ```

4. Copy `terraform/environments/dev.backend.hcl.example` and `production.backend.hcl.example` to private local backend config files, setting the output bucket and lock-table names. These config files must not be committed if they contain account-specific details.
5. Initialize the main Terraform root for exactly one environment at a time, for example:

   ```sh
   terraform -chdir=terraform init -backend-config=environments/dev.backend.hcl
   terraform -chdir=terraform plan -var-file=environments/dev.tfvars -out=dev.tfplan
   ```

   Add a reviewed `cluster_version` value to the selected tfvars only after verifying EKS, module, and add-on compatibility. Keep plan files private; they may contain sensitive values.

The `dev` and `production` backend examples use distinct S3 keys so their states do not overlap. The dev example intentionally retains the repository's former `eks/terraform.tfstate` key to avoid silently creating an empty parallel state. Verify the existing state contents and ownership before initializing; if that key belongs to another environment, plan an explicit state migration with the operator. The bucket and DynamoDB table are shared, while environment state keys and `.tfvars` stay separate.
