locals {
  notification_thresholds = {
    for notification in flatten([
      for notification_type in ["ACTUAL", "FORECASTED"] : [
        for threshold in var.alert_threshold_percentages : {
          key               = "${notification_type}-${threshold}"
          notification_type = notification_type
          threshold         = threshold
        }
      ]
    ]) : notification.key => notification
  }

  budget_name = "${var.project_name}-${var.environment}-monthly-cost"
}

# This is deliberately account-wide: EKS, EC2, NAT, ALB, EBS, logging, and
# other AWS costs can continue even when the demo application is not in use.
# Cost alerts are advisory; AWS Budgets does not stop or cap spending.
resource "aws_budgets_budget" "monthly_account_cost" {
  name         = local.budget_name
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_amount_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = local.notification_thresholds

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.notification_type
      subscriber_email_addresses = sort(tolist(var.alert_email_addresses))
    }
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "Demo cost visibility"
  }
}
