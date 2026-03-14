# BOOTSTRAP-OUTLINE-NOTES.md — Self-Hosted Outline Wiki Setup

> **Run this once to set up a private Outline wiki for team knowledge sharing.**
> If `memory/.bootstrapped-outline` exists, skip.

## Overview

Outline is a self-hosted team wiki deployed on ECS Fargate, private to the team via Cognito auth. No public access. Used to share runbooks, architecture docs, and daily logs between Loki and the operator.

**Stack:**
- Outline wiki (Docker) → ECS Fargate
- Aurora PostgreSQL → wiki database
- ElastiCache Redis → sessions/cache
- Cognito User Pool → SSO auth (OIDC)
- ALB → CloudFront (HTTPS termination)
- Loki → daily workspace sync cron

---

## Part 1: Infrastructure

### Prerequisites

- VPC with private subnets
- Aurora Serverless v2 (PostgreSQL-compatible) cluster
- ElastiCache Redis cluster (single node is fine)
- ECS cluster
- ALB + target group
- CloudFront distribution in front of ALB

### Cognito Setup

Create a Cognito User Pool for Outline:

```bash
# Create pool
aws cognito-idp create-user-pool \
  --pool-name outline-wiki \
  --policies "PasswordPolicy={MinimumLength=8,RequireUppercase=false,RequireLowercase=false,RequireNumbers=false,RequireSymbols=false}" \
  --region us-east-1

# Create app client (note the ClientId — you'll need it)
aws cognito-idp create-user-pool-client \
  --user-pool-id YOUR_POOL_ID \
  --client-name outline \
  --generate-secret \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes openid email profile \
  --callback-urls "https://YOUR_OUTLINE_URL/auth/oidc.callback" \
  --logout-urls "https://YOUR_OUTLINE_URL" \
  --supported-identity-providers COGNITO \
  --region us-east-1

# Create domain
aws cognito-idp create-user-pool-domain \
  --domain faststart-outline \
  --user-pool-id YOUR_POOL_ID \
  --region us-east-1
```

Add team members as Cognito users:
```bash
aws cognito-idp admin-create-user \
  --user-pool-id YOUR_POOL_ID \
  --username teammate@example.com \
  --user-attributes Name=email,Value=teammate@example.com \
  --temporary-password TempPass123 \
  --region us-east-1
```

### Secrets

Store these in Secrets Manager — **never in task definitions or env files**:

```bash
# Generate and store Outline secrets
SECRET_KEY=$(openssl rand -hex 32)
UTILS_SECRET=$(openssl rand -hex 32)

aws secretsmanager create-secret \
  --name /outline/secret-key \
  --secret-string "$SECRET_KEY" \
  --region us-east-1

aws secretsmanager create-secret \
  --name /outline/utils-secret \
  --secret-string "$UTILS_SECRET" \
  --region us-east-1

aws secretsmanager create-secret \
  --name /outline/database-url \
  --secret-string "postgres://outline:PASSWORD@YOUR_AURORA_ENDPOINT:5432/outline" \
  --region us-east-1

aws secretsmanager create-secret \
  --name /outline/oidc-client-secret \
  --secret-string "YOUR_COGNITO_CLIENT_SECRET" \
  --region us-east-1
```

> ⚠️ Reference these via `secrets:` in the ECS task definition — never pass as plaintext `environment:` values.

### ECS Task Definition

```json
{
  "family": "outline",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "containerDefinitions": [{
    "name": "outline",
    "image": "docker.getoutline.com/outlinewiki/outline:latest",
    "portMappings": [{"containerPort": 3000}],
    "environment": [
      {"name": "NODE_ENV", "value": "production"},
      {"name": "PORT", "value": "3000"},
      {"name": "FORCE_HTTPS", "value": "false"},
      {"name": "URL", "value": "https://YOUR_CLOUDFRONT_URL"},
      {"name": "FILE_STORAGE", "value": "local"},
      {"name": "FILE_STORAGE_LOCAL_ROOT_DIR", "value": "/var/lib/outline/data"},
      {"name": "PGSSLMODE", "value": "require"},
      {"name": "DATABASE_CONNECTION_POOL_MIN", "value": "2"},
      {"name": "DATABASE_CONNECTION_POOL_MAX", "value": "10"},
      {"name": "REDIS_URL", "value": "redis://YOUR_REDIS_ENDPOINT:6379"},
      {"name": "OIDC_CLIENT_ID", "value": "YOUR_COGNITO_CLIENT_ID"},
      {"name": "OIDC_DISPLAY_NAME", "value": "AWS Cognito"},
      {"name": "OIDC_USERNAME_CLAIM", "value": "email"},
      {"name": "OIDC_SCOPES", "value": "openid email profile"},
      {"name": "OIDC_AUTH_URI", "value": "https://faststart-outline.auth.us-east-1.amazoncognito.com/oauth2/authorize"},
      {"name": "OIDC_TOKEN_URI", "value": "https://faststart-outline.auth.us-east-1.amazoncognito.com/oauth2/token"},
      {"name": "OIDC_USERINFO_URI", "value": "https://faststart-outline.auth.us-east-1.amazoncognito.com/oauth2/userInfo"},
      {"name": "OIDC_LOGOUT_URI", "value": "https://faststart-outline.auth.us-east-1.amazoncognito.com/logout"}
    ],
    "secrets": [
      {"name": "SECRET_KEY", "valueFrom": "arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:/outline/secret-key"},
      {"name": "UTILS_SECRET", "valueFrom": "arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:/outline/utils-secret"},
      {"name": "DATABASE_URL", "valueFrom": "arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:/outline/database-url"},
      {"name": "OIDC_CLIENT_SECRET", "valueFrom": "arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:/outline/oidc-client-secret"}
    ]
  }]
}
```

### Deploy ECS Service

```bash
aws ecs create-service \
  --cluster outline \
  --service-name outline \
  --task-definition outline \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[SUBNET_ID],securityGroups=[SG_ID],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=TARGET_GROUP_ARN,containerName=outline,containerPort=3000" \
  --region us-east-1
```

---

## Part 2: Verify Outline is Running

Before setting up sync, confirm Outline is accessible:

```bash
# Check ECS service is stable
aws ecs describe-services --cluster outline --services outline --region us-east-1 \
  --query 'services[0].{status:status,running:runningCount,desired:desiredCount}'

# Expected: {"status": "ACTIVE", "running": 1, "desired": 1}
```

Open the URL in a browser and log in with a Cognito user. Create at least one collection (e.g. "FastStart Ops") before enabling the sync.

---

## Part 3: Create Outline API Token

After logging in:
1. Go to **Settings → API tokens**
2. Create a token named `loki-sync`
3. Store it in Secrets Manager:

```bash
aws secretsmanager create-secret \
  --name /outline/api-token \
  --secret-string "YOUR_OUTLINE_API_TOKEN" \
  --region us-east-1
```

Note the collection IDs you want to sync to (visible in the URL when browsing a collection).

---

## Part 4: Set Up Workspace Sync Cron

Once Outline is running and you have an API token, add the sync cron to OpenClaw:

```
/cron add "Outline workspace sync" --schedule "0 2 * * *" --message "Sync workspace documentation to Outline wiki. Use the outline skill. Upload updated MEMORY.md, SOUL.md, AGENTS.md, HEARTBEAT.md, and any memory/ files changed today. Create or update documents in the FastStart Ops collection. Report what was synced."
```

Add the project guidelines audit cron:

```
/cron add "Project guidelines audit" --schedule "0 9 * * *" --message "Audit all active repos against project guidelines: IaC-first, no hardcoded secrets, README present, CI/CD pipeline configured. Upload the full report to Outline in the Reports collection. Alert on critical violations."
```

**Key collection IDs (update for your instance):**
- FastStart Ops: create via Outline UI, note the UUID from the URL
- Reports: create via Outline UI, note the UUID — used for audit reports

---

## COGNITO_DOMAIN Gotcha

The `COGNITO_DOMAIN` env var (used by the Outline Cognito adapter) must be **just the prefix**, not the full URL:

```
✅ faststart-outline
❌ https://faststart-outline.auth.us-east-1.amazoncognito.com
```

The adapter builds the full URL internally. Passing the full URL causes it to double up: `https://https://...`.

---

## Finish

```bash
mkdir -p memory && echo "Outline bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-outline
```
