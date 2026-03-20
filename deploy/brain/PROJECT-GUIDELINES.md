# Project Guidelines Template

Copy this template when starting a new AWS project/app.


---

## Project: *{name}*

### Overview

* **URL:** *(CloudFront URL)*
* **CloudFront Distribution:** *(ID)*
* **VPC:** *(VPC ID, CIDR)*
* **Stack:** *(e.g., ECS Fargate + Aurora + S3 + CloudFront + Cognito)*
* **Cognito Client:** *(app client ID)*

### Architecture

```
User → CloudFront → ALB (CF-only SG) → ECS Fargate (ARM64)
                                         ↕
                                    Aurora / DynamoDB
```

### Infrastructure Checklist

- [ ] VPC with private subnets (no public subnets for app resources)
- [ ] VPC Endpoints (ECR, S3, Logs, SecretsManager) — no NAT Gateway
- [ ] ALB restricted to CloudFront prefix list
- [ ] ECS Fargate ARM64 with distroless containers
- [ ] Container Insights enabled on cluster
- [ ] CloudFront with security headers (HSTS, CSP, X-Frame-Options)
- [ ] WAF rules (OWASP Core, rate limiting)
- [ ] Cognito auth (shared pool or app-specific)
- [ ] Lambda@Edge for auth cookie
- [ ] VPC Flow Logs enabled
- [ ] git-secrets hooks installed
- [ ] Terraform in `infra/{app-name}/terraform/`
- [ ] INFRASTRUCTURE.md documenting everything
- [ ] Registered in app-registry (DynamoDB or equivalent)

### CI/CD Pipeline

* **Source:** CodeCommit or GitHub (via CodeStar Connection)
* **Build:** CodeBuild (ARM64 compute)
* **Deploy:** ECR → ECS Fargate (rolling update)
* **Pipeline:** CodePipeline

#### buildspec.yml Template

```yaml
version: 0.2
env:
  variables:
    ECR_REPO: "{account}.dkr.ecr.{region}.amazonaws.com/{app}"
phases:
  pre_build:
    commands:
      - aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_REPO
      - IMAGE_TAG=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-7)
  build:
    commands:
      - cd $CODEBUILD_SRC_DIR
      - docker build -t $ECR_REPO:$IMAGE_TAG -t $ECR_REPO:latest .
      - docker push $ECR_REPO:$IMAGE_TAG
      - docker push $ECR_REPO:latest
  post_build:
    commands:
      - printf '[{"name":"{container}","imageUri":"%s"}]' $ECR_REPO:$IMAGE_TAG > imagedefinitions.json
artifacts:
  files: imagedefinitions.json
```

### Monitoring

- [ ] CloudWatch dashboards (CPU, memory, request count, errors)
- [ ] Synthetics canary for uptime
- [ ] SNS alerts for alarms
- [ ] Inspector scanning on ECR images

### Cost Estimate

| Resource | Monthly Cost |
|----------|--------------|
| ECS Fargate (0.25 vCPU / 512MB) | \~$10        |
| ALB      | \~$16        |
| CloudFront | \~$1         |
| VPC Endpoints | \~$7 each    |
| Aurora Serverless v2 (shared) | \~$0 incremental |
| **Total** | **\~$35-50** |

### Security

* Cognito admin-only registration
* HttpOnly auth cookies
* WAF rate limiting
* ALB restricted to CloudFront
* Distroless containers, non-root
* Secrets in Secrets Manager
* VPC Flow Logs


---

*Delete sections that don't apply. Add app-specific details as you build.*