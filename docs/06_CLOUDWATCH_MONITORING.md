# CloudWatch Monitoring Guide

Everything you need to observe what your serverless application is doing in real time.

---

## Log Groups

Lambda automatically creates CloudWatch Log Groups. No setup needed.

| Log Group | What it contains |
|---|---|
| `/aws/lambda/nse-api-staging` | Every API request: method, path, status, duration |
| `/aws/lambda/nse-api-prod` | Same for prod |
| `/aws/lambda/nse-scraping-worker-staging` | Each scraping task: asin, success/fail, error |
| `/aws/lambda/nse-scraping-worker-prod` | Same for prod |
| `/aws/lambda/nse-screener-refresh-staging` | Scheduled screener job runs |
| `/aws/lambda/nse-dlq-alert-staging` | DLQ alerts sent to SNS |
| `/aws/apigateway/nse-api-staging` | API Gateway access logs (IP, latency, status) |

---

## View logs from terminal

```bash
# Tail live API logs (staging)
make logs STAGE=staging
# or directly:
aws logs tail /aws/lambda/nse-api-staging --follow --region ap-south-1

# Tail live worker logs
make logs-worker STAGE=staging

# Last 30 minutes of errors only
aws logs filter-log-events \
  --log-group-name /aws/lambda/nse-api-staging \
  --filter-pattern "ERROR" \
  --start-time $(($(date +%s) - 1800))000 \
  --region ap-south-1

# Find all failed scraping tasks
aws logs filter-log-events \
  --log-group-name /aws/lambda/nse-scraping-worker-staging \
  --filter-pattern "FAIL" \
  --region ap-south-1
```

---

## CloudWatch Insights queries

Go to **CloudWatch → Logs Insights** and run these queries.

### API error rate (last 1 hour)
```
SOURCE '/aws/lambda/nse-api-staging'
| filter @message like /ERROR/
| stats count() as error_count by bin(5m)
| sort bin(5m) asc
```

### Slowest API routes (p99 latency)
```
SOURCE '/aws/apigateway/nse-api-staging'
| fields routeKey, status, responseLength
| stats count() as calls, avg(responseLength) as avg_bytes by routeKey
| sort calls desc
| limit 20
```

### Scraping success rate
```
SOURCE '/aws/lambda/nse-scraping-worker-staging'
| filter @message like /DONE|FAIL/
| stats count(@message) as total,
        sum(@message like /DONE/) as success,
        sum(@message like /FAIL/) as failed
```

### Lambda cold starts
```
SOURCE '/aws/lambda/nse-api-staging'
| filter @message like /Init Duration/
| stats count() as cold_starts, avg(@duration) as avg_init_ms
```

---

## Alarms

Run `bash infrastructure/cloudwatch/setup_alarms.sh staging <api-gw-id>` to create:

| Alarm | Condition | Action |
|---|---|---|
| `nse-lambda-api-errors-staging` | Lambda errors > 0 in 5 min | SNS email |
| `nse-lambda-worker-errors-staging` | Worker errors > 0 in 5 min | SNS email |
| `nse-sqs-dlq-depth-staging` | DLQ visible messages > 0 | SNS email |
| `nse-apigw-5xx-staging` | API 5xx > 10 in 5 min | SNS email |
| `nse-lambda-screener-errors-staging` | Screener Lambda errors > 0 | SNS email |
| `nse-lambda-universe-errors-staging` | Universe Lambda errors > 0 | SNS email |

View in console: **CloudWatch → Alarms → filter: `nse-*-staging`**

---

## Dashboard

Each stage has a pre-built dashboard at:
**CloudWatch → Dashboards → NSE-Operations-staging**

Panels:
1. **Lambda Invocations & Errors** — API + Worker + Screener calls per 5 min
2. **SQS Queue Depth** — main queue + DLQ (DLQ should always be 0)
3. **API Gateway Requests & Errors** — total req, 4xx, 5xx per 5 min
4. **Lambda Duration** — p50 and p99 response time
5. **DynamoDB RCU/WCU** — consumed read/write capacity

---

## Lambda metrics explained

| Metric | Healthy value | Warning |
|---|---|---|
| `Invocations` | Any | N/A |
| `Errors` | 0 | > 0 = something broken |
| `Throttles` | 0 | > 0 = hit concurrency limit |
| `Duration p99` | < 5000 ms | > 25000 ms = close to timeout |
| `ConcurrentExecutions` | < 100 | > 500 = check quota |

Free tier gives 400,000 GB-seconds/month. With 512 MB Lambda and average 2-second responses:
- 400,000 / (0.5 GB × 2 s) = 400,000 free invocations/month

---

## What to do when an alarm fires

### DLQ depth > 0 (scraping job permanently failed)
```bash
# See what's in the DLQ
aws sqs receive-message \
  --queue-url <dlq-url> \
  --region ap-south-1

# Look at the task in DynamoDB
aws dynamodb get-item \
  --table-name stg_scraping_tasks \
  --key '{"task_id": {"S": "<task-id>"}}' \
  --region ap-south-1
```
Common causes: Amazon CAPTCHA, ASIN removed from site, network timeout.

### API Lambda errors
```bash
# Get recent error logs
aws logs filter-log-events \
  --log-group-name /aws/lambda/nse-api-staging \
  --filter-pattern "ERROR" \
  --region ap-south-1 \
  --limit 20
```

### API Gateway 5xx spike
Check if the Lambda function has errors (see above). Also check DynamoDB throttles:
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name SystemErrors \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum \
  --region ap-south-1
```

---

## X-Ray tracing (optional)

Add distributed tracing to see exactly which DynamoDB call is slow:

```bash
# Enable X-Ray on Lambda
aws lambda update-function-configuration \
  --function-name nse-api-staging \
  --tracing-config Mode=Active \
  --region ap-south-1
```

Then: **CloudWatch → X-Ray Traces** — see end-to-end request maps including DynamoDB latency.

Free tier: 100,000 traces/month forever.
