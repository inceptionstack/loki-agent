# Loki: Your Stateful Dev/Research/Sec/Ops Agent in your AWS account

> **TL;DR — one command to deploy:**
> ```
> bash <(curl -sfL https://raw.githubusercontent.com/inceptionstack/loki-agent/main/install.sh)
> ```
> Requires: AWS CLI configured, admin access on a dedicated AWS account. The script walks you through everything.
>
> After your first chat, run the [Bootstrap Scripts](https://github.com/inceptionstack/loki-agent/wiki/Bootstrap-Scripts-Guide) to set up security, skills, memory search, and more.

---
## What's This Experiment About?
What if you gave OpenClaw its own AWS account to manage and control, and ask it to build stuff for you?

## The Problem: Infrastructure Eats Your Time

Building a prototype has never been faster. Tools like Lovable, Base44, and Bolt let any developer go from idea to working demo in minutes. For simple frontend apps with basic CRUD, these platforms deliver genuine speed. The prototype side of the equation is largely solved.

The problem begins the moment a team decides to build something real on AWS. Even experienced engineers who know exactly what they want to build spend days on infrastructure before writing a single line of business logic: provisioning compute, designing IAM policies, configuring networking, setting up CI/CD pipelines, instrumenting monitoring, and establishing security baselines. For a solo founder or a small team without dedicated DevOps resources, this can create huge delays or might mean never get to a shipping product fast enough (or at all).

The alternative is (and what most solo founders and scrappy teams might do) building quickly on a rapid-development platform and migrating to AWS later. That creates a different set of problems. These platforms are "black box", can't access real AWS services except what is prescribed (if at all), and require complete rewrites when teams outgrow them. The technical debt accumulates silently until someone needs a (different, or more complicated) payment integration, a compliance requirement, or a workload the platform simply can't support (special backend APIs or even an API only product, specialized data schemas or graphs, special scale provisions, specialized security options and more). At that point, the team faces a choice between a costly rewrite and staying on a platform that limits what they can build.

**It would be great if developers didn't have to choose between speed and control.**


---

## Why This Is Solvable Now

Three capabilities have converged to make this problem solvable for the first time.

**1. AI agents that actually work.** OpenClaw (and other claw-like tools), the open-source AI agent framework, proved at scale that users (some are developers) will trust an AI agent to execute shell commands, manage files, and interact with APIs — when the agent is capable and the human retains control. It reached 317k GitHub stars in 6 weeks, one of the fastest adoption curves in open-source history.

**2. Infrastructure-as-code is mature.** aws-cli, Terraform, AWS CDK, CloudFormation,  SAM and other tooling make resource provisioning fully programmable. An AI agent can generate, modify, and deploy infrastructure using the same tools a human engineer would use — producing output that is auditable, version-controlled, and reversible.

**3. Foundation models can reason about architecture.** Models like Anthropic Claude support the context windows and tool-use reliability required for multi-step infrastructure provisioning. They can reason about full-stack application architecture, generate correct configurations, and maintain context across multi-hour build sessions.

These three capabilities are the building blocks. **Loki is what you get when you combine them into a single, deployable package, and then give it its own AWS account to administer 24/7.**


---

## What Loki Does

Loki is an open-source, deploy-it-yourself AI agent that lives in your AWS account (usually one per account so the agents don't step on each other's toes) and builds real code, infrastructure, deployments and configurations. 

Clone the repo, deploy via CloudFormation, SAM, or Terraform, and within minutes you have a 24/7 agent running in your account , connected to Amazon Bedrock (by default, you can change that), loaded with AWS infrastructure skills, and ready to build. The agent is accessible via Telegram, Discord, Slack, or a terminal UI, and maintains full memory across sessions so it always knows what it built, what's deployed, and what state everything is in.

Loki handles the complete build lifecycle inside your AWS account:

* **Designs and deploys** serverless APIs, container workloads, and data pipelines
* **Writes application code**, pushes to repositories, and triggers CI/CD pipelines
* **Configures IAM policies**, security groups, and compliance logging
* **Sets up CloudWatch monitoring** and security services automatically
* **Debugs production issues** — reads CloudTrail logs, identifies root causes, and applies fixes

Everything Loki builds can use (but is not limited to) standard AWS services: CloudFormation or CDK or Terraform for infrastructure, CodeCommit or GitHub for code, Lambda or ECS for compute, DynamoDB or RDS for data. There's no proprietary runtime, no abstraction layer, and no migration required when your application grows beyond the prototype stage.

**You own everything.** Disable Loki tomorrow and your applications keep running. Every resource is visible in the AWS console, portable to any toolchain, and yours to modify.

### Difference from Cursor, Claude Code, Kiro and others

Unlike **AI coding tools** (Cursor, Kiro, Claude Code) that run on your laptop and stop when the laptop closes, Loki is a persistent agent that lives in your AWS account around the clock. Start a build on Tuesday, come back Thursday, and it knows exactly where things stand.

### Difference from Lovable, Bolt, Base44 etc

Unlike **rapid-dev platforms** (Replit, Lovable, Bolt) that abstract away infrastructure and trap your code in proprietary runtimes, Loki works *within* AWS. Your infrastructure is real AWS, managed by standard IaC tools, with no outside vendor lock-in (except AWS of course, but you could choose to build fully containerized apps with it so you can easily port them in the future).

### Difference from Standard OpenClaw Assistants

Unlike a **general-purpose AI assistants**, Loki ships with AWS infrastructure skills, security best practices baked in, and the IAM permissions to actually provision resources. It's purpose-built for building and operating on AWS. **Instead of being fully locked down into a VM sandbox or docker sandbox, it's sandbox is defined by the boundaries of the AWS account it lives in.**

It does not bundle any clawhub skills (huge security risk there), but comes with mostly AWS skills and playwright MCP using mcporter.


---

## How It Works

Loki is built on [OpenClaw](https://github.com/openclaw/openclaw), the open-source AI agent framework. The [loki-agent](https://github.com/inceptionstack/loki-agent) repository packages everything needed to deploy a production-ready Loki instance:

**1. One-click deployment.** Choose your IaC tool  (CloudFormation, SAM, or Terraform) and deploy. The template creates an isolated VPC, a T4g.xlarge EC2 instance by default (recommended so it can really do things like build run tests, build code, dockerize things and more, as a real dev machine), IAM roles, security services, and installs Loki with a pre-configured workspace. Total deploy time: \~4-10 minutes.

**2. Configurable security posture.** The deployment includes five individually toggleable security services — Security Hub, GuardDuty, Inspector, Access Analyzer, and AWS Config  all enabled by default. For test/dev environments, disable what you don't need. The EC2 instance uses SSM Session Manager instead of SSH (no open ports), and the Loki gateway only listens on localhost (not exposed to the network).

**3. Observe → Plan → Act.** Loki reads the current state of your AWS account, plans the next actions, and executes them with full admin power. **(remember - with power comes resposibility. this is risky, so use it on a clean AWS account to minize blast radius of agent making mistakes)**

**4. Persistent memory.** Conversation history and agent memory are stored locally on the instance. Loki maintains workspace files (SOUL.md, TOOLS.md, MEMORY.md) that give it continuity across sessions and restarts. It knows what it built yesterday. 

**5. Your data stays yours.** The only external calls are to Amazon Bedrock for AI inference (processed under the Bedrock data privacy policy — your data is not used to train models). Alternatively, use your own Anthropic API key or a LiteLLM proxy. No code, infrastructure configurations, or application data leaves your account.


---

## Who It's For

**Solo founders and pre-seed teams (1–3 people)** frustrated by rapid-dev platform limitations such as no custom backend, no real AWS services, no path to production, who need to iterate quickly without accumulating technical debt.

**Small startup teams (2–10 people)** racing toward product-market fit with limited runway. They need sophisticated backend capabilities like payments, integrations, compliance and can't afford dedicated DevOps resources or have too much work on their hands already.

**Corporate innovation teams** building proofs of concept. They must comply with corporate security standards, can't use external platforms that require data to leave their AWS account, and are measured by speed of validation.

**Any developer** who knows what they want to build on AWS but doesn't want to spend a week on infrastructure before writing business logic to build a POC.


---

## Getting Started

### Option 1: One-command install (recommended)

```bash
bash <(curl -sfL https://raw.githubusercontent.com/inceptionstack/loki-agent/main/install.sh)
```

The installer verifies your AWS credentials, checks permissions, lets you pick an instance size and deployment method (CloudFormation/SAM/Terraform), deploys everything, and monitors progress until Loki is ready.

### Option 2: Manual deploy

```bash
# Clone
git clone https://github.com/inceptionstack/loki-agent.git
cd loki-agent/deploy/cloudformation

# Deploy
aws cloudformation create-stack \
  --stack-name my-loki \
  --template-body file://template.yaml \
  --parameters ParameterKey=EnvironmentName,ParameterValue=my-loki \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1

# Wait ~10 min, then connect
aws ssm start-session --target <instance-id>

# Talk to your Loki
openclaw tui
```

Full deployment guide: [Deploying Loki on AWS](https://github.com/inceptionstack/loki-agent/wiki/Deploying-Loki-on-AWS)

### Uninstall

Remove one or all Loki deployments from your account:

```bash
bash <(curl -sfL https://raw.githubusercontent.com/inceptionstack/loki-agent/main/uninstall.sh)
```

Finds deployments by tag, lets you pick which to remove, deletes CloudFormation stacks or cleans up resources manually (Terraform deploys), and optionally removes state buckets/lock tables.


---

## Principles


1. **Production-shaped from the start.** Every application Loki builds (assuming given the right instructions and system prompt) includes infrastructure as code, CI/CD, monitoring, and scoped IAM . A prototype that can't be promoted to production is a demo, not a prototype.
2. **You own everything.** Loki operates inside your AWS account. Every resource it creates is visible in the console, portable to any toolchain, and fully functional if the agent is removed. No abstraction layer, no vendor lock-in, no proprietary runtime.
3. **Speed without shortcuts.** Loki collapses code + deploy + infrastructure setup from days to minutes. This can include security configuration, monitoring, and CI/CD.
4. **Transparency over autonomy.** Every action is logged to CloudTrail. You can see exactly what Loki built, modified, or deleted at any time.  This also allows powerful debugging of failing apps while it happens, with fast corrections. 
5. **Meet developers where they are.** Accessible from Telegram, Discord, Slack, or a terminal.


---

## Cost Estimates

| Component | Estimated Monthly Cost |
|-----------|------------------------|
| EC2 t4g.medium (24/7) | \~$25                  |
| EC2 t4g.xlarge (24/7) (recommended for complex dev work) | \~$100                 |
| EBS volumes (40GB + 80GB) | \~$10                  |
| Bedrock (moderate use, sonnet 4.6) (recommended: opus 4.6 for main tasks, sonnet 4.6 for subagents) assuming you're building every day. | $300–$2000 (or much more if you're very active on opus 4.6)             |
| Security services | \~$5 (individually toggleable) |
|           |                        |
|           |                        |

Loki can estimate costs before provisioning resources and summarize your actual AWS spend at any time. Set [AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html) alerts during setup.


---

## Limitations

Loki is:

* **Non-deterministic.** Given the same request, it may produce different results. For complex architecture, a developer/architect with AWS experience gets significantly better results — the agent amplifies expertise, it doesn't substitute for it.
* **Single-account scope.** Loki operates within one AWS account. It's not designed for multi-account orchestration (yet).
* **Not a compliance auditor.** Loki will try to follow security best practices and enable security services by default, but doesn't replace formal compliance auditing.
* **Prototyping-to-production, not at-scale operations.** Loki can monitor and debug what it builds, but it's not a replacement for dedicated operations tooling for high-scale production workloads.


---

## Open Source

Loki is fully open source. The deployment templates, brain files, skills, and bootstrap scripts are all available at [github.com/inceptionstack/loki-agent](https://github.com/inceptionstack/loki-agent).

Built on [OpenClaw](https://github.com/openclaw/openclaw) — the engine that powers the agent runtime, tool execution, and memory system.

Contributions, issues, and feedback welcome.
