variable "aws_region" {
  description = "AWS Budgets API signing region. Keep this at us-east-1; it does not select the region for any workload resource."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project label used in the budget name and tags."
  type        = string
  default     = "elastiflix"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,40}$", var.project_name))
    error_message = "project_name must be 1-40 characters and contain only letters, digits, period, underscore, or hyphen."
  }
}

variable "environment" {
  description = "Environment label used in the budget name and tags."
  type        = string
  default     = "demo"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,20}$", var.environment))
    error_message = "environment must be 1-20 characters and contain only letters, digits, period, underscore, or hyphen."
  }
}

variable "monthly_budget_amount_usd" {
  description = "Operator-selected monthly USD alert threshold for total AWS account costs. An alert threshold, not a spending cap and not an estimate."
  type        = number

  validation {
    condition     = var.monthly_budget_amount_usd > 0
    error_message = "monthly_budget_amount_usd must be greater than zero."
  }
}

variable "alert_email_addresses" {
  description = "Approved notification recipients. Keep account-specific addresses in an ignored local tfvars file, never in Git."
  type        = set(string)
  sensitive   = true

  validation {
    condition     = length(var.alert_email_addresses) > 0
    error_message = "Provide at least one approved alert_email_addresses recipient."
  }
}

variable "alert_threshold_percentages" {
  description = "Distinct percentages of the monthly budget that trigger both actual-cost and forecasted-cost email notifications."
  type        = list(number)
  default     = [25, 50, 75, 100]

  validation {
    condition = length(var.alert_threshold_percentages) > 0 &&
      length(distinct(var.alert_threshold_percentages)) == length(var.alert_threshold_percentages) &&
      alltrue([for threshold in var.alert_threshold_percentages : threshold > 0 && threshold <= 100])
    error_message = "alert_threshold_percentages must be non-empty, distinct values greater than 0 and no more than 100."
  }
}
