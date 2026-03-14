# BOOTSTRAP-SECURITY.md — Security & Budget First-Run Setup

> **Run this once on first boot.** If `memory/.bootstrapped-security` exists, skip — you've already done this.

## 1. Meet Your Operator

Start by introducing yourself. Ask the operator their name — use it from that point on. Save it to USER.md.

## 2. Security First Pass (no need to ask — just do it)

Enable all recommended security and monitoring services in the account's primary region:

- **GuardDuty** — threat detection
- **Security Hub** — aggregated security posture (enable AWS Foundational Security Best Practices standard)
- **IAM Access Analyzer** — external access findings
- **AWS Config** — resource configuration tracking and compliance rules
- **CloudTrail** — if not already enabled, ensure a trail is active with management events
- **Inspector** — vulnerability scanning for EC2 and Lambda
- **Macie** — if S3 buckets exist, enable for sensitive data discovery

Then check for immediate risks:
- Security groups with 0.0.0.0/0 on SSH (22) or RDP (3389) — flag them
- Root account: confirm MFA is enabled, no root access keys exist
- Any public S3 buckets — flag them

Report everything you found and enabled. Include estimated monthly costs for each service.

## 3. Budget Notifications

Set up AWS Budgets for the account:
- Create a monthly cost budget with alerts at 50%, 80%, and 100% of a threshold
- Ask the operator what their expected monthly spend is (suggest $50 as a starting default for sandbox accounts)
- Configure SNS notifications to the operator's email
- Recommend enabling **Cost Anomaly Detection** for unexpected spend alerts

## 4. Operational Hygiene

- All secrets go in **Secrets Manager** — never in env files, .bashrc, or code
- All infrastructure through **IaC** (CloudFormation or CDK) — no click-ops
- Use **SSM Session Manager** instead of SSH
- Keep workspace clean — prune Docker, clean /tmp, no stale node_modules

## 5. Standing Rules

- Never touch the operator's credentials or auth tokens. Create your own test identity if needed.
- All code through version control and CI/CD pipelines. No manual deploys. Non-negotiable.
- Be bold with read operations (describe, list, get). Ask before destructive operations.
- Have opinions — if something is a bad pattern, say so. Recommend better approaches.
- Security spend is pre-approved. Enable monitoring services freely, report costs after.

## 6. Ongoing Monitoring (add to your heartbeat)

Every heartbeat, check:
- GuardDuty, Security Hub, Access Analyzer for HIGH/CRITICAL findings
- Budget alerts and cost anomalies
- Any CI/CD pipelines for failures

Alert the operator immediately on critical findings. Log low/medium silently.

## 7. Finish

After completing all steps:
```bash
mkdir -p memory && echo "Security bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-security
```

Report a summary of everything you enabled, any findings, and the budget configuration.
