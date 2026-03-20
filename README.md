# loki-bootstrap

Bootstrap prompts and deployment templates for running Loki (powered by [OpenClaw](https://github.com/inceptionstack/openclaw) on AWS. Deploy a fully configured Loki AI ops assistant with a single command).

> **📖 New to this?** Read the [complete deployment guide](wiki/Deploying-Loki-on-AWS.md) — covers account setup, security, budgets, and FAQ.

---

## Table of Contents

- [Quick Start](#quick-start)
- [What Gets Deployed](#what-gets-deployed)
- [Parameters Reference](#parameters-reference)
- [Model Modes](#model-modes)
- [Post-Deployment](#post-deployment)
- [Bootstrap Prompts](#bootstrap-prompts)
- [Brain Files](#brain-files)
- [Security](#security)
- [Contributing](#contributing)

---

## Quick Start

Choose one of three deployment methods. All deploy the same architecture.

### Option 1: CloudFormation (Console)

1. Download `deploy/cloudformation/template.yaml`
2. Open the [CloudFormation Console](https://console.aws.amazon.com/cloudformation/home#/stacks/create)
3. Upload the template, fill in parameters, and create the stack
4. Wait for `CREATE_COMPLETE` (~8–10 minutes)

### Option 2: SAM CLI

```bash
sam build -t deploy/sam/template.yaml
sam deploy \
  --guided \
  --template-file deploy/sam/template.yaml \
  --stack-name openclaw-stack \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
```

### Option 3: Terraform

```bash
cd deploy/
terraform init
terraform plan -var="environment_name=openclaw"
terraform apply -var="environment_name=openclaw"
```

Override variables in a `terraform.tfvars` file or with `-var` flags.

---

## What Gets Deployed

The stack provisions a self-contained Loki environment:

```
┌──────────────────────────────────────────────────┐
│  VPC (10.0.0.0/16)                               │
│  ├─ Public Subnet + Internet Gateway             │
│  ├─ EC2 Instance (Loki runtime)              │
│  │   ├─ openclaw-bootstrap.sh (first boot)       │
│  │   ├─ openclaw-config-gen.py (config setup)    │
│  │   ├─ bedrock-motd.sh (Bedrock helper)         │
│  │   └─ litellm-setup.sh (LiteLLM proxy)        │
│  └─ Security Group (SSM + optional SSH)          │
│                                                  │
│  Lambda Custom Resources                         │
│  ├─ Config generation                            │
│  └─ Post-deploy validation                       │
│                                                  │
│  Security Services                               │
│  ├─ AWS Security Hub                             │
│  ├─ Amazon Inspector                             │
│  ├─ AWS Budgets                                  │
│  └─ IAM (least-privilege roles)                  │
└──────────────────────────────────────────────────┘
```

**Key components:**

- **VPC** — Isolated network with public subnet and internet gateway
- **EC2 Instance** — Runs the Loki agent runtime (via OpenClaw); bootstrapped on first boot via `openclaw-bootstrap.sh`
- **Lambda Custom Resources** — Handle config generation and post-deploy validation during stack creation
- **Security Services** — Security Hub, Inspector, and budgets enabled by default
- **IAM Roles** — Least-privilege roles for EC2 (Bedrock access, SSM, CloudWatch) and Lambda

---

## Parameters Reference

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| `EnvironmentName` | Name prefix for all resources | `openclaw` | Yes |
| `InstanceType` | EC2 instance type | `t3.medium` | No |
| `ModelMode` | AI model backend — `bedrock`, `litellm`, or `api-key` | `bedrock` | Yes |
| `DefaultModel` | Default model ID for the agent | `anthropic.claude-sonnet-4-20250514` | No |
| `BedrockRegion` | AWS region for Bedrock API calls | `us-east-1` | No |
| `LiteLLMBaseUrl` | LiteLLM proxy endpoint (required if `ModelMode=litellm`) | — | Conditional |
| `LiteLLMApiKey` | API key for LiteLLM proxy (required if `ModelMode=litellm`) | — | Conditional |
| `BootstrapScriptUrl` | URL to a custom bootstrap script (overrides default) | — | No |
| `SSHAllowedCidr` | CIDR block allowed for SSH access; leave empty to disable SSH | — | No |

> Parameters may vary slightly between the CloudFormation, SAM, and Terraform templates. Refer to the specific template file for the full list.

---

## Model Modes

The `ModelMode` parameter controls how Loki connects to language models.

### `bedrock` (default)

Uses Amazon Bedrock directly. The EC2 instance role includes Bedrock permissions. No external API keys needed.

- Set `BedrockRegion` to the region where your models are enabled
- Set `DefaultModel` to a Bedrock model ID (e.g. `anthropic.claude-sonnet-4-20250514`)
- The `bedrock-motd.sh` helper validates Bedrock access on boot

### `litellm`

Routes requests through a [LiteLLM](https://github.com/BerriAI/litellm) proxy, allowing access to multiple providers through a unified API.

- Set `LiteLLMBaseUrl` to your LiteLLM endpoint
- Set `LiteLLMApiKey` to your proxy API key
- The `litellm-setup.sh` helper configures the proxy connection on boot

### `api-key`

Uses a provider API key directly (e.g. Anthropic API key). Configure the key and endpoint in the Loki config after deployment.

---

## Post-Deployment

### Connect via SSM

SSH is optional. The recommended way to connect is through AWS Systems Manager Session Manager:

```bash
# Find the instance ID
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*openclaw*" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text

# Start a session
aws ssm start-session --target <instance-id>
```

### Check Bootstrap Status

Once connected, check that the bootstrap completed successfully:

```bash
# View bootstrap log
cat /var/log/openclaw-bootstrap.log

# Check Loki service status
systemctl status openclaw
```

### Configure Channels

After deployment, configure messaging channels (Telegram, Slack, etc.) by following the relevant optional bootstrap prompts or editing the Loki config directly:

```bash
# Loki config location
cat /opt/openclaw/config.yaml
```

---

## Bootstrap Prompts

Bootstrap prompts are instruction files that Loki executes on first boot (or on demand) to configure its environment. Each creates a marker file in `memory/` to prevent re-running.

### Essential (`essential/`)

Run these in order on new instances:

| # | File | Purpose |
|---|------|---------|
| 1 | [BOOTSTRAP-SECURITY.md](essential/BOOTSTRAP-SECURITY.md) | Security Hub, Inspector, budgets, WAF, operational hygiene |
| 2 | [BOOTSTRAP-SECRETS-AWS.md](essential/BOOTSTRAP-SECRETS-AWS.md) | AWS Secrets Manager integration, exec provider, troubleshooting |
| 3 | [BOOTSTRAP-SKILLS.md](essential/BOOTSTRAP-SKILLS.md) | Install the FastStart skills library |
| 4 | [BOOTSTRAP-MEMORY-SEARCH.md](essential/BOOTSTRAP-MEMORY-SEARCH.md) | Semantic memory search with embedrock + Cohere Embed v4 on Bedrock |
| 5 | [BOOTSTRAP-CODING-GUIDELINES.md](essential/BOOTSTRAP-CODING-GUIDELINES.md) | Coding standards — testing, linting, commit conventions, CI/CD |
| 6 | [BOOTSTRAP-DISK-SPACE-STRAT.md](essential/BOOTSTRAP-DISK-SPACE-STRAT.md) | Secondary EBS data volume, nightly cleanup cron, Docker/tmp offloading |
| 7 | [BOOTSTRAP-DAILY-UPDATE.md](essential/BOOTSTRAP-DAILY-UPDATE.md) | Daily morning briefing — costs, security findings, pipeline health |

### Optional (`optional/`)

Add as needed:

| File | Purpose |
|------|---------|
| [BOOTSTRAP-MODEL-CONFIG.md](optional/BOOTSTRAP-MODEL-CONFIG.md) | Configure AI models (Sonnet default, Opus fallback) to save tokens |
| [BOOTSTRAP-TELEGRAM.md](optional/BOOTSTRAP-TELEGRAM.md) | Telegram bot setup, Loki wiring, formatting/reaction rules |
| [BOOTSTRAP-OUTLINE-NOTES.md](optional/BOOTSTRAP-OUTLINE-NOTES.md) | Self-hosted Outline wiki (ECS + Aurora + S3 + Cognito OIDC) |
| [BOOTSTRAP-PIPELINE-NOTIFICATIONS.md](optional/BOOTSTRAP-PIPELINE-NOTIFICATIONS.md) | CodePipeline + GitHub Actions alerts to Telegram + Loki |
| [BOOTSTRAP-GITHUBACTION-CODE-REVIEW.md](optional/BOOTSTRAP-GITHUBACTION-CODE-REVIEW.md) | Automatic Claude Code PR + commit review via GitHub Actions |
| [BOOTSTRAP-WEB-UI.md](optional/BOOTSTRAP-WEB-UI.md) | Control UI via CloudFront + Cognito — ALB, proxy, WebSocket |
| [OPTIMIZE-TOO-LARGE-CONTEXT.md](optional/OPTIMIZE-TOO-LARGE-CONTEXT.md) | Reduce context window usage, memory management, compaction |

> **Built-in (no bootstrap needed):** Heartbeat monitoring, daily memory logging, and long-term recall are part of the Loki runtime.

---

## Brain Files

The `deploy/brain/` directory contains template workspace files that define the agent's personality, behavior, and team structure. These are copied into the Loki workspace during bootstrap.

| File | Purpose |
|------|---------|
| `SOUL.md` | Core personality, communication style, and behavioral rules |
| `AGENTS.md` | Agent role definitions and capabilities |

### Customizing

Edit the brain files before deployment to tailor the agent to your needs:

- **SOUL.md** — Adjust tone, response style, channel-specific rules, and operational boundaries
- **AGENTS.md** — Define which agent roles are available and their responsibilities

Brain files are loaded into the agent's workspace at `/opt/openclaw/brain/` and can be edited post-deployment as well.

---

## Security

### Enabled by Default

The deployment enables several AWS security services:

- **AWS Security Hub** — Centralized security findings and compliance checks
- **Amazon Inspector** — Automated vulnerability scanning for the EC2 instance
- **AWS Budgets** — Cost monitoring and alerts
- **IAM Least Privilege** — EC2 and Lambda roles follow least-privilege principles

### Network Security

- The EC2 instance runs in a VPC with a single public subnet
- SSH access is disabled by default; set `SSHAllowedCidr` to enable it
- SSM Session Manager is the recommended access method (no inbound ports required)
- Security groups restrict traffic to only what is necessary

### Admin User

The bootstrap creates an admin user for the Loki runtime. Credentials are stored in AWS Secrets Manager and can be retrieved via the AWS Console or CLI:

```bash
aws secretsmanager get-secret-value --secret-id <environment-name>/openclaw/admin
```

### Bootstrap Security Prompt

The `BOOTSTRAP-SECURITY.md` essential prompt hardens the environment further by configuring WAF rules, operational hygiene practices, and security monitoring.

---

## Contributing

### Adding New Bootstrap Prompts

Create a new `BOOTSTRAP-*.md` file following the existing pattern:

1. Add a marker file check at the top (`memory/.bootstrapped-*`)
2. Write clear, numbered steps
3. Create the marker file on completion
4. Use `YOUR_VALUE` placeholders instead of real secrets
5. Place in `essential/` or `optional/` as appropriate

### Modifying Deployment Templates

The three deployment methods (CloudFormation, SAM, Terraform) should stay functionally equivalent. When modifying one template, update the others to match.

### Project Structure

```
loki-bootstrap/
├── essential/              # Required bootstrap prompts
├── optional/               # Optional bootstrap prompts
├── deploy/
│   ├── template.yaml           # CloudFormation template
│   ├── sam-template.yaml       # SAM template
│   ├── main.tf                 # Terraform config
│   ├── variables.tf            # Terraform variables
│   ├── outputs.tf              # Terraform outputs
│   ├── providers.tf            # Terraform providers
│   ├── openclaw-bootstrap.sh   # EC2 bootstrap script
│   ├── openclaw-config-gen.py  # Config generator
│   ├── bedrock-motd.sh         # Bedrock MOTD/fix helper
│   ├── litellm-setup.sh        # LiteLLM proxy setup
│   └── brain/                  # Template workspace files
│       ├── SOUL.md
│       └── AGENTS.md
└── README.md
```

---

## Related Projects

- [openclaw](https://github.com/inceptionstack/openclaw) — The OpenClaw agent runtime
- [loki-skills](https://github.com/inceptionstack/loki-skills) — Skills library
- [embedrock](https://github.com/inceptionstack/embedrock) — Bedrock embedding proxy

---

## License

See [LICENSE](LICENSE) for details.
