# CloudWatch Monitoring — Multi-Account

## Important: logs are per-account

Each AWS account has its own CloudWatch. Always specify the correct AWS profile:

```bash
# Staging account logs
export AWS_PROFILE=aws-staging && make logs STAGE=staging

# Prod account logs
export AWS_PROFILE=aws-prod && make logs STAGE=prod
```

## Log Groups (per account)

| Log Group | What it shows |
|---|---|
| `/aws/lambda/nse-api-staging` | Every API request (auth, users, stocks, scraping) |
| `/aws/lambda/nse-scraping-worker-staging` | Each ASIN scrape: success/fail/error |
| `/aws/lambda/nse-ws-staging` | WebSocket connect/disconnect/subscribe |
| `/aws/lambda/nse-dynamo-streams-staging` | WebSocket push events |
| `/aws/lambda/nse-ses-notifications-staging` | Email sends |
| `/aws/lambda/nse-dlq-alert-staging` | Permanently failed scraping tasks |
| `/aws/apigateway/nse-api-staging` | API GW access log: IP, latency, status |
| `/aws/states/nse-scraping-staging` | Step Functions execution logs |

## Live log commands

```bash
# Tail any log group live
aws logs tail /aws/lambda/nse-api-staging --follow --region ap-south-1

# Filter for errors only
aws logs filter-log-events \
  --log-group-name /aws/lambda/nse-api-staging \
  --filter-pattern "ERROR" \
  --region ap-south-1

# Filter for a specific user
aws logs filter-log-events \
  --log-group-name /aws/lambda/nse-api-staging \
  --filter-pattern "user_id=abc-123" \
  --region ap-south-1

# Step Functions execution errors
aws logs filter-log-events \
  --log-group-name /aws/states/nse-scraping-staging \
  --filter-pattern "ExecutionFailed" \
  --region ap-south-1
```

## Alarms (6 per account)

Run `make setup-cloudwatch` to create these in each account:

| Alarm | Threshold | Meaning |
|---|---|---|
| `nse-lambda-api-errors` | errors > 0 in 5 min | Lambda handler crashed |
| `nse-lambda-worker-errors` | errors > 0 in 5 min | Scraping Lambda crashed |
| `nse-sqs-dlq-depth` | messages > 0 | ASIN failed 3 times permanently |
| `nse-apigw-5xx` | 5xx > 10 in 5 min | API returning server errors |
| `nse-lambda-screener-errors` | errors > 0 | Screener cache broken |
| `nse-lambda-universe-errors` | errors > 0 | NSE symbol list not updated |

All alarms → SNS → email to your address.

## Dashboard: NSE-Operations-staging / NSE-Operations-prod

AWS Console → CloudWatch → Dashboards → NSE-Operations-staging

**Panels:**
1. Lambda Invocations & Errors (API + Worker + Screener + Universe)
2. SQS Queue Depth (main queue + DLQ)
3. API Gateway Requests & Errors (4xx, 5xx)
4. Lambda Duration p50/p99
5. DynamoDB Consumed RCU/WCU
6. Step Functions Executions (success vs fail)
7. WebSocket Connections (active count)
8. X-Ray: slowest traces

## X-Ray service map

AWS Console → CloudWatch → X-Ray Traces → Service Map

Shows:
- Every Lambda function as a node
- Lines connecting Lambda → DynamoDB, Lambda → SQS, etc.
- Color coding: green (OK), red (errors), yellow (slow)
- Click any node → see individual traces
- Click any trace → see exactly which DynamoDB call took 200ms

Useful for:
- Finding slow endpoints
- Tracking down which external API call is failing
- Understanding request flow

## CloudWatch Insights — useful queries

Open: Console → CloudWatch → Logs Insights → select log group → run query

**API error rate by route (last 1 hour):**
```
SOURCE '/aws/lambda/nse-api-staging'
| filter @message like /ERROR/
| parse @message "* handler error: *" as handler, error
| stats count() as errors by handler
| sort errors desc
```

**Slowest Lambda invocations:**
```
SOURCE '/aws/lambda/nse-api-staging'
| filter @type = "REPORT"
| fields @requestId, @duration, @billedDuration, @memorySize, @maxMemoryUsed
| sort @duration desc
| limit 20
```

**Scraping success rate:**
```
SOURCE '/aws/lambda/nse-scraping-worker-staging'
| filter @message like /DONE|FAIL/
| stats
    count(@message) as total,
    sum((@message like /DONE/) == 1) as success,
    sum((@message like /FAIL/) == 1) as failed
```

**WebSocket connection activity:**
```
SOURCE '/aws/lambda/nse-ws-staging'
| filter @message like /connect|disconnect|subscribe/
| stats count() as events by bin(5m)
| sort bin(5m) asc
```

## What to do when an alarm fires

**Lambda errors alarm:**
```bash
# Get last 20 errors with context
aws logs filter-log-events \
  --log-group-name /aws/lambda/nse-api-staging \
  --filter-pattern "ERROR" \
  --region ap-south-1 \
  --limit 20 | jq '.events[].message'
```

**SQS DLQ alarm (scraping permanently failed):**
```bash
# See what's in the DLQ
DLQ_URL=$(aws sqs get-queue-url --queue-name nse-scraping-jobs-staging-dlq \
  --query QueueUrl --output text --region ap-south-1)
aws sqs receive-message --queue-url $DLQ_URL --region ap-south-1

# Check the task in DynamoDB
aws dynamodb get-item --table-name scraping_tasks \
  --key '{"task_id":{"S":"<task-id>"}}' --region ap-south-1
```
