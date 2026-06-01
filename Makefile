# ══════════════════════════════════════════════════════════════════════════════
#  NSE Stock Dashboard — 100% Serverless AWS (40+ services, zero EC2)
#
#  QUICK START (local dev):
#    make local-backend      FastAPI on localhost:9000 (for dev only)
#    make local-frontend     React  on localhost:3000
#
#  ONE-TIME INFRA SETUP (run once per stage):
#    make setup-all STAGE=staging EMAIL=you@email.com
#    make setup-all STAGE=prod    EMAIL=you@email.com
#
#  DEPLOY (after every code change):
#    make deploy STAGE=staging    → Lambda + S3 frontend
#    make deploy STAGE=prod
#
#  MONITOR:
#    make logs STAGE=staging      CloudWatch live logs
#    make logs-worker             Worker Lambda logs
#    make health                  Health check both stages
#    make xray                    Open X-Ray trace console
#
#  AWS SERVICES USED (free tier):
#    API Gateway (HTTP + WebSocket) · Lambda · DynamoDB · DynamoDB Streams
#    S3 · CloudFront · Cognito · SQS · SNS · EventBridge · Step Functions
#    SES · SSM · AppConfig · X-Ray · CloudWatch · CloudTrail · IAM · KMS
#    Comprehend · Translate · Rekognition · CodeBuild · Resource Groups
#    Budgets · Lambda Layers · CloudFront Functions · Shield Standard
# ══════════════════════════════════════════════════════════════════════════════

STAGE  ?= staging
REGION ?= ap-south-1
EMAIL  ?= set-your@email.com

# Function names derived from stage
FUNCS := nse-api nse-scraping-worker nse-ws nse-dynamo-streams nse-ses-notifications

# Read from SSM (no hardcoded values)
STAGING_API_URL := $(shell aws ssm get-parameter --name /nse/staging/api-gateway-url \
  --query Parameter.Value --output text 2>/dev/null || echo "")
PROD_API_URL    := $(shell aws ssm get-parameter --name /nse/prod/api-gateway-url \
  --query Parameter.Value --output text 2>/dev/null || echo "")
S3_BUCKET       := $(shell aws ssm get-parameter --name /nse/$(STAGE)/s3-frontend-bucket \
  --query Parameter.Value --output text 2>/dev/null || echo "SET_BUCKET")

.PHONY: help local-backend local-frontend install-backend install-frontend \
        deploy deploy-layer deploy-api deploy-worker deploy-ws deploy-frontend \
        setup-all setup-iam setup-s3 setup-dynamo setup-cognito setup-sqs \
        setup-sns setup-ssm setup-stepfunctions setup-websocket setup-ses \
        setup-appconfig setup-kms setup-eventbridge setup-cloudwatch \
        setup-cloudfront setup-codebuild setup-budget setup-tags \
        logs logs-worker logs-ws health xray dynamo-tables lint

help:
	@echo ""
	@echo "  NSE Stock Dashboard — 40+ AWS Free-Tier Services"
	@echo ""
	@echo "  LOCAL"
	@echo "    make local-backend    FastAPI on localhost:9000 (dev mode)"
	@echo "    make local-frontend   React on localhost:3000"
	@echo ""
	@echo "  ONE-TIME SETUP  (add STAGE=prod for prod)"
	@echo "    make setup-all STAGE=staging EMAIL=you@email.com"
	@echo ""
	@echo "  DEPLOY"
	@echo "    make deploy STAGE=staging      Full deploy (Lambda + frontend)"
	@echo "    make deploy-layer              Deploy shared Lambda Layer"
	@echo "    make deploy-api                Deploy API Lambda only"
	@echo "    make deploy-worker             Deploy scraping worker"
	@echo "    make deploy-ws                 Deploy WebSocket Lambda"
	@echo "    make deploy-frontend           Build React + upload to S3"
	@echo ""
	@echo "  MONITOR"
	@echo "    make logs STAGE=staging        Live API Lambda logs"
	@echo "    make logs-worker               Worker Lambda logs"
	@echo "    make health                    Curl both stage health endpoints"
	@echo "    make xray                      Open X-Ray service map URL"
	@echo ""

# ── Local development ─────────────────────────────────────────────────────────
install-backend:
	cd backend && pip install -r requirements.txt

install-frontend:
	cd frontend && npm install

local-backend:
	@echo "→ FastAPI on http://localhost:9000/docs  (STAGE=staging)"
	@echo "  Note: In production, API Gateway routes directly to Lambda handlers"
	cd backend && STAGE=staging uvicorn app.main:app --reload --host 0.0.0.0 --port 9000

local-frontend:
	cd frontend && npm start

# ── Deploy all Lambdas ────────────────────────────────────────────────────────
deploy: deploy-layer deploy-api deploy-worker deploy-ws deploy-frontend
	@echo "✓ Full $(STAGE) deploy complete"

deploy-layer:
	bash infrastructure/lambda/layer/deploy.sh $(STAGE)

deploy-api:
	bash infrastructure/lambda/api/deploy.sh $(STAGE)

deploy-worker:
	bash infrastructure/lambda/scraping_worker/deploy.sh $(STAGE)

deploy-ws:
	bash infrastructure/websocket/setup_websocket_api.sh $(STAGE)

deploy-frontend:
	bash infrastructure/scripts/frontend_deploy.sh $(STAGE) $(S3_BUCKET)

# ── Monitor ───────────────────────────────────────────────────────────────────
logs:
	@echo "→ CloudWatch logs: nse-api-$(STAGE)"
	aws logs tail /aws/lambda/nse-api-$(STAGE) --follow --region $(REGION)

logs-worker:
	aws logs tail /aws/lambda/nse-scraping-worker-$(STAGE) --follow --region $(REGION)

logs-ws:
	aws logs tail /aws/lambda/nse-ws-$(STAGE) --follow --region $(REGION)

health:
	@echo "→ Staging:"; \
	  [ -n "$(STAGING_API_URL)" ] && \
	  curl -fsS "$(STAGING_API_URL)/api/v1/health/" && echo " ✓" || echo " ✗ URL not set"
	@echo "→ Prod:"; \
	  [ -n "$(PROD_API_URL)" ] && \
	  curl -fsS "$(PROD_API_URL)/api/v1/health/" && echo " ✓" || echo " ✗ URL not set"

xray:
	@echo "→ X-Ray Service Map:"
	@echo "  https://$(REGION).console.aws.amazon.com/xray/home#/service-map"

# ── Infrastructure setup ──────────────────────────────────────────────────────
setup-all:
	@echo "═══════════════════════════════════════════════"
	@echo "  Full infrastructure setup — STAGE=$(STAGE)"
	@echo "═══════════════════════════════════════════════"
	$(MAKE) setup-iam
	$(MAKE) setup-s3
	$(MAKE) setup-dynamo
	$(MAKE) setup-sqs
	$(MAKE) setup-sns
	$(MAKE) setup-ssm
	$(MAKE) setup-cognito
	$(MAKE) deploy-layer
	$(MAKE) deploy-api
	$(MAKE) deploy-worker
	$(MAKE) setup-apigateway
	$(MAKE) setup-stepfunctions
	$(MAKE) setup-websocket
	$(MAKE) setup-ses
	$(MAKE) setup-appconfig
	$(MAKE) setup-kms
	$(MAKE) setup-eventbridge
	$(MAKE) setup-cloudwatch
	$(MAKE) setup-cloudfront
	$(MAKE) setup-budget
	$(MAKE) setup-tags
	@echo "═══════════════════════════════════════════════"
	@echo "  ✓ All $(STAGE) infrastructure ready!"
	@echo "═══════════════════════════════════════════════"

setup-iam:
	bash infrastructure/iam/setup_lambda_role.sh

setup-s3:
	bash infrastructure/scripts/s3_setup.sh

setup-dynamo:
	STAGE=$(STAGE) AWS_REGION=$(REGION) python3 infrastructure/dynamodb/create_tables.py

setup-sqs:
	bash infrastructure/sqs/setup_sqs.sh $(STAGE)

setup-sns:
	bash infrastructure/sns/setup_sns.sh $(STAGE) $(EMAIL)

setup-ssm:
	bash infrastructure/ssm/setup_ssm.sh $(STAGE)

setup-cognito:
	bash infrastructure/cognito/setup_cognito.sh $(STAGE) $(EMAIL)

setup-apigateway:
	bash infrastructure/scripts/api_gateway_setup.sh $(STAGE)

setup-stepfunctions:
	bash infrastructure/stepfunctions/setup_stepfunctions.sh $(STAGE)

setup-websocket:
	bash infrastructure/websocket/setup_websocket_api.sh $(STAGE)

setup-ses:
	bash infrastructure/ses/setup_ses.sh $(STAGE) $(EMAIL)

setup-appconfig:
	bash infrastructure/appconfig/setup_appconfig.sh $(STAGE)

setup-kms:
	bash infrastructure/kms/setup_kms.sh $(STAGE)

setup-eventbridge:
	bash infrastructure/eventbridge/setup_eventbridge.sh $(STAGE)

setup-cloudwatch:
	@API_GW_ID=$$(aws ssm get-parameter --name /nse/$(STAGE)/api-gateway-id \
	  --query Parameter.Value --output text 2>/dev/null || echo ""); \
	bash infrastructure/cloudwatch/setup_alarms.sh $(STAGE) "$${API_GW_ID}"

setup-cloudfront:
	bash infrastructure/cloudfront/setup_cloudfront.sh $(STAGE)

setup-codebuild:
	bash infrastructure/codebuild/setup_codebuild.sh $(STAGE)

setup-budget:
	bash infrastructure/scripts/setup_budget.sh $(EMAIL)

setup-tags:
	bash infrastructure/scripts/setup_resource_groups.sh $(STAGE)

dynamo-tables:
	STAGE=$(STAGE) AWS_REGION=$(REGION) python3 infrastructure/dynamodb/create_tables.py

lint:
	ruff check backend/handlers/ backend/app/ --fix
