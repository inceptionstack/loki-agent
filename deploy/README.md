# Deploy Loki on AWS

Deploy a fully configured [Loki](https://github.com/inceptionstack/loki-bootstrap) (powered by [OpenClaw](https://github.com/openclaw/openclaw)) AI assistant on your own AWS account. Choose your preferred IaC tool — all three options deploy identical infrastructure.

## Prerequisites

- AWS account with admin access
- Bedrock model access enabled (the template auto-submits the use case form, but model activation can take ~15 minutes)
- One of: AWS CLI, SAM CLI, or Terraform installed

## Choose Your Deployment Method

| Method | Folder | Best For |
|--------|--------|----------|
| [CloudFormation](cloudformation/) | `deploy/cloudformation/` | Console deploys, StackSets, Organizations |
| [SAM](sam/) | `deploy/sam/` | Serverless-familiar teams, `sam deploy --guided` |
| [Terraform](terraform/) | `deploy/terraform/` | Terraform shops, multi-cloud workflows |

## What Gets Deployed

All three methods create the same architecture:

- **VPC** — isolated VPC with public subnet, internet gateway, route table
- **EC2 Instance** — ARM64 Graviton (AL2023), root + data EBS volumes (gp3, encrypted)
- **IAM** — instance role (AdministratorAccess + SSM), admin IAM user with console password
- **Security Services** — SecurityHub, GuardDuty, Inspector, Access Analyzer, Config (via Lambda custom resources)
- **Bedrock** — use case form auto-submitted, optional quota increase requests
- **OpenClaw** — installed via bootstrap script, systemd gateway service, brain workspace files

## Key Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `EnvironmentName` | `openclaw` | Prefix for all resource names |
| `InstanceType` | `t4g.xlarge` | EC2 instance type (ARM64 Graviton only) |
| `ModelMode` | `bedrock` | `bedrock` (IAM), `litellm` (proxy), or `api-key` (direct) |
| `DefaultModel` | `us.anthropic.claude-opus-4-6-v1` | Bedrock model ID |
| `BedrockRegion` | `us-east-1` | Region for Bedrock API calls |
| `SSHAllowedCidr` | `127.0.0.1/32` | SSH access CIDR (disabled by default — use SSM) |
| `LiteLLMBaseUrl` | *(empty)* | LiteLLM proxy URL (only when `ModelMode=litellm`) |
| `BootstrapScriptUrl` | GitHub raw URL | URL to the bootstrap script |

## Post-Deployment

### Connect via SSM Session Manager

```bash
aws ssm start-session --target <instance-id> --region us-east-1
```

### Check OpenClaw Status

```bash
openclaw status
openclaw logs --follow
```

### Configure a Chat Channel

```bash
openclaw configure
# Follow the wizard to set up Telegram, Discord, Slack, etc.
```

### Admin Console Access

The template creates an IAM admin user (`<EnvironmentName>-admin`) with a random password stored in Secrets Manager:

```bash
aws secretsmanager get-secret-value --secret-id openclaw/admin-password \
  --region us-east-1 --query SecretString --output text | jq .
```

## Shared Files

Files at the `deploy/` level are used by all deployment methods:

- `openclaw-bootstrap.sh` — main EC2 bootstrap script (installs Node, OpenClaw, Claude Code, etc.)
- `openclaw-config-gen.py` — generates Loki config based on model mode
- `bedrock-motd.sh` — writes MOTD + fix script if Bedrock form submission fails
- `litellm-setup.sh` — helper to patch an existing Loki config with LiteLLM proxy settings
- `brain/` — template workspace files (SOUL.md, AGENTS.md, etc.) copied to each new instance
