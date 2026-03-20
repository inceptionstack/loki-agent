# TOOLS.md — Local Notes & AWS Guidance

Skills define *how* tools work. This file is for *your* specifics — environment details, learned patterns, and operational knowledge.


---

## AWS Setup Checklist (New Account)

### First Things First


1. **Note your Account ID, Region, IAM Role, and Instance ID** — you'll reference these constantly
2. **Check your IAM permissions** — `aws sts get-caller-identity` and `aws iam list-attached-role-policies`
3. **Set default region** — `export AWS_DEFAULT_REGION=us-east-1` (or your region)

### Security Baseline

- [ ] Enable Security Hub + CIS Benchmarks: `aws securityhub enable-security-hub`
- [ ] Enable Inspector for ECR + Lambda: `aws inspector2 enable --resource-types ECR LAMBDA LAMBDA_CODE`
- [ ] Enable VPC Flow Logs on all VPCs
- [ ] Enable EBS default encryption: `aws ec2 enable-ebs-encryption-by-default`
- [ ] Set up budget alerts: `aws budgets create-budget`
- [ ] Install `git-secrets` pre-commit hooks on all repos
- [ ] Delete default VPCs (AWS security best practice): `aws ec2 delete-vpc --vpc-id <default-vpc>`
- [ ] Configure fail2ban on your instance

### Infrastructure Patterns That Work

**Always use VPC Endpoints over NAT Gateway** — massive cost savings:

```bash
# Essential endpoints for ECS/ECR workloads:
aws ec2 create-vpc-endpoint --vpc-id $VPC --service-name com.amazonaws.$REGION.ecr.api --vpc-endpoint-type Interface
aws ec2 create-vpc-endpoint --vpc-id $VPC --service-name com.amazonaws.$REGION.ecr.dkr --vpc-endpoint-type Interface
aws ec2 create-vpc-endpoint --vpc-id $VPC --service-name com.amazonaws.$REGION.s3 --vpc-endpoint-type Gateway
aws ec2 create-vpc-endpoint --vpc-id $VPC --service-name com.amazonaws.$REGION.logs --vpc-endpoint-type Interface
aws ec2 create-vpc-endpoint --vpc-id $VPC --service-name com.amazonaws.$REGION.secretsmanager --vpc-endpoint-type Interface
```

**ALB restricted to CloudFront only:**

```hcl
# In security group — use managed prefix list
ingress {
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
}
```

**CloudFront + Cognito auth pattern:**

* Lambda@Edge for auth cookie (`HttpOnly`, `Secure`, `SameSite=Lax`)
* Cookie name convention: `{app-name}-auth`
* Cognito user pool shared across apps (cost-effective)

### ECS Fargate Patterns

**Always specify ARM64 runtime platform** — Fargate defaults to x86:

```json
{
  "runtimePlatform": {
    "cpuArchitecture": "ARM64",
    "operatingSystemFamily": "LINUX"
  }
}
```

**Distroless containers, non-root runtime:**

```dockerfile
FROM node:24-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
RUN npm run build

FROM gcr.io/distroless/nodejs24-debian12
COPY --from=builder /app/dist /app/dist
COPY --from=builder /app/node_modules /app/node_modules
USER nonroot
CMD ["app/dist/index.js"]
```

**Container Insights** — enable on every cluster:

```bash
aws ecs update-cluster-settings --cluster $CLUSTER \
  --settings name=containerInsights,value=enabled
```

### CodePipeline / CodeBuild

**⚠️ ALWAYS use** `**$CODEBUILD_SRC_DIR**` **in buildspec.yml:** `cd` does NOT persist between commands or phases in CodeBuild. Never write `cd somedir && ...` — always `cd $CODEBUILD_SRC_DIR/somedir && ...`.

**ARM64 cross-compilation in CodeBuild:**

```yaml
# For building ARM64 Docker images on AMD64 CodeBuild:
phases:
  install:
    commands:
      - docker buildx create --use
      - docker run --privileged --rm tonistiigi/binfmt --install arm64
  build:
    commands:
      - docker buildx build --platform linux/arm64 -t $IMAGE --load .
```

**GitHub source via CodeStar Connection:**

```bash
aws codestar-connections create-connection --provider-type GitHub --connection-name my-github
# Then authorize in AWS Console (one-time)
```

**Never use** `**|| echo**` **on critical deployment commands** — silently swallows failures. Your deployment looks green but the old version keeps running forever.

### DynamoDB Patterns

**Always paginate Scans** — 1MB limit per call:

```javascript
let items = [];
let lastKey;
do {
  const result = await client.send(new ScanCommand({
    TableName: table,
    ExclusiveStartKey: lastKey,
  }));
  items.push(...result.Items);
  lastKey = result.LastEvaluatedKey;
} while (lastKey);
```

**Type N (Number) sort keys** — if your sort key is type N, always use numbers. Strings like `'REPO'` cause silent failures with no error.

### Networking Gotchas

* **Public IP without IGW route = no internet** — always check subnet route tables
* **NLB + k8s SG management:** Use `spec.loadBalancerSourceRanges` on k8s Service. Manual SG edits get reverted by k8s controller.
* **Instance target type preserves client source IP** (NLB), IP target type doesn't
* **IMDSv2 hop limit = 2** for Docker containers (default 1 doesn't work inside containers)

### CloudFront Tips

* **Cache invalidation required after deploys:** `aws cloudfront create-invalidation --distribution-id $DIST --paths "/*"`
* **WebSocket support:** Use `AllViewer` managed origin request policy + `CachingDisabled` cache policy
* **CloudFront Function targeted apply trick:** Can't delete old CF Function while distribution references it — use `terraform apply -target=` for new function + distribution first, then full apply to delete old one
* **CloudFront adds NO cost savings for uploads** ($0.02/GB = same as direct cross-region). Savings only on download/serving.

### Monitoring

**Synthetics canary alarm fix:** Period must match canary interval (e.g., 1800s for 30-min canaries) and `treatMissingData=notBreaching`.

**CloudWatch Log Insights** for ECS debugging:

```
fields @timestamp, @message
| filter @message like /ERROR/
| sort @timestamp desc
| limit 50
```

### Lambda Patterns

* **API Gateway WebSocket has 29s integration timeout** — hard limit. For long operations, use async self-invocation pattern.
* **Model ID format matters:** Use `anthropic.claude-sonnet-4-20250514-v1:0` (no `us.` prefix for ConverseStream)

## Shared Auth Pattern

Convention: Single Cognito pool shared across all apps. Each app gets its own client ID. Login: same email/password everywhere.

* Store credentials in Secrets Manager, never in code
* No MFA (unless your human wants it)
* Admin-only registration (disable self-signup)

## File Sharing Pattern

Upload to S3 → serve via CloudFront:

```bash
aws s3 cp <file> s3://<assets-bucket>/assets/exports/<filename> \
  --content-type "text/markdown; charset=utf-8" \
  --content-disposition "attachment; filename=<filename>"
```

## Brain Backup Pattern

S3 bucket with Intelligent-Tiering, versioning, KMS encryption. Cron every 6h:

```bash
#!/bin/bash
BUCKET="brain-backup-$(aws sts get-caller-identity --query Account --output text)"
WORKSPACE="$HOME/.openclaw/workspace"
aws s3 sync "$WORKSPACE/" "s3://$BUCKET/brain/" \
  --exclude ".git/*" --exclude "node_modules/*" --exclude "*.pyc"
aws s3 sync "$WORKSPACE/memory/" "s3://$BUCKET/memory/"
```

## What Else Goes Here

* Camera names and locations
* SSH hosts and aliases
* Preferred voices for TTS
* Speaker/room names
* Device nicknames
* Anything environment-specific


---

*Add whatever helps you do your job. This is your cheat sheet.*