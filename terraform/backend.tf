terraform {
  # No hard-coded bucket or lock table: those are account- and environment-
  # specific and used to be duplicated in three places. Supply them at init time:
  #
  #   terraform init -backend-config=environments/dev.backend.hcl
  #
  # Creating the bucket/table is out of scope here on purpose - the bucket must
  # exist before init can run. See terraform/backend-bootstrap.tf for the
  # durability settings that root enforces on the existing resources.
  backend "s3" {}
}
