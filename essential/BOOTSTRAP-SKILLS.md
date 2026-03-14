# BOOTSTRAP-SKILLS.md — Skills Library Setup

> **Run this once on first boot.** If `memory/.bootstrapped-skills` exists, skip — you've already done this.

## 1. Install Skills

Clone the FastStart skills library into your workspace:

```bash
cd ~/.openclaw/workspace
git clone https://github.com/inceptionstack/loki-skills.git skills
```

This gives you specialized skills for:

| Category | Skills |
|----------|--------|
| **AWS Core** | aws-mcp, aws-infrastructure-as-code, cloud-architect, aws-agentcore |
| **Observability** | aws-observability, cloudwatch-application-signals, datadog, dynatrace |
| **Migration** | aws-graviton-migration, arm-soc-migration |
| **AI/ML** | strands, claude-agent-sdk, spark-troubleshooting-agent |
| **Serverless** | aws-amplify, lambda-durable, aws-healthomics |
| **Infrastructure** | terraform, saas-builder, cfn-stacksets |
| **Payments** | stripe, checkout |
| **DevOps** | figma, postman, neon, outline, reposwarm |
| **Testing** | cross-agent-test |

OpenClaw auto-discovers skills from the `skills/` directory — they're available immediately after cloning.

## 2. Verify

List the installed skills to confirm they're loaded:

```bash
ls -1 ~/.openclaw/workspace/skills/
```

Review what you have and tell the operator what capabilities are now available.

## 3. Keeping Skills Updated

To update skills later:

```bash
cd ~/.openclaw/workspace/skills && git pull
```

Consider adding this to a weekly cron to stay current.

## 4. Finish

After completing all steps:
```bash
mkdir -p memory && echo "Skills bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-skills
```

Report the full list of installed skills to the operator.
