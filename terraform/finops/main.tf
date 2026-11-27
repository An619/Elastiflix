locals {
  # Both ACTUAL and FORECASTED notifications at every threshold: a forecast alert
  # is the only warning that arrives before the money is already spent.
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

# Deliberately account-wide: EKS, EC2, NAT, ALB, EBS, logging and data transfer
# keep billing while the demo application is idle. If the account is shared, the
# alerts include costs that are not Elastiflix's.
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
}
