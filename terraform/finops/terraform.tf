terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Local state on purpose: a budget is a single account-level object, and
  # provisioning a second remote-state backend just to hold it would add cost and
  # a bootstrap dependency. The state file can contain notification addresses, so
  # it must stay untracked and be protected like a secret.
}
