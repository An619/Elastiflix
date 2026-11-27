output "budget_name" {
  description = "Name of the account-wide monthly cost budget."
  value       = aws_budgets_budget.monthly_account_cost.name
}

output "notification_thresholds" {
  description = "Thresholds that will send an actual-cost and a forecasted-cost email, expressed as percentages of the limit."
  value       = sort([for key, item in local.notification_thresholds : "${item.notification_type}:${item.threshold}%"])
}
