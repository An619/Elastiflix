terraform {
  # Supply an environment-specific backend config during `terraform init`.
  # See terraform/environments/*.backend.hcl.example. Backend resources must
  # be created first from terraform/backend-bootstrap using local state.
  backend "s3" {}
}
