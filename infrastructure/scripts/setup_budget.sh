#!/bin/bash
# AWS Budgets — cost alert if free tier is exceeded
# Free tier: 2 free budgets. Extra budgets cost $0.02/day.
# This creates 1 budget alerting if monthly spend > $1 (safety net)
# Usage: bash infrastructure/scripts/setup_budget.sh your@email.com
set -e
EMAIL="${1:?Usage: $0 <alert-email>}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"  # Budgets API is global, but must use us-east-1

echo "Creating AWS Budget alert..."
aws budgets create-budget \
  --account-id "${ACCOUNT_ID}" \
  --budget '{
    "BudgetName": "NSE-MonthlySpend",
    "BudgetLimit": {"Amount": "1.00", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers "[{
    \"Notification\": {
      \"NotificationType\": \"ACTUAL\",
      \"ComparisonOperator\": \"GREATER_THAN\",
      \"Threshold\": 50,
      \"ThresholdType\": \"PERCENTAGE\"
    },
    \"Subscribers\": [{\"SubscriptionType\":\"EMAIL\",\"Address\":\"${EMAIL}\"}]
  }]" \
  --region "${REGION}" > /dev/null 2>/dev/null && \
  echo "Budget created: alert when spend > \$0.50/month" || \
  echo "Budget already exists"

echo ""
echo "View in console: AWS → Billing → Budgets → NSE-MonthlySpend"
echo "You'll receive email if monthly AWS spend exceeds \$0.50"
