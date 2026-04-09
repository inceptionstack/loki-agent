# BOOTSTRAP-DEVOPS-AGENT.md — Set Up AWS DevOps Agent Skill

> **Applies to:** Agents with AWS account access (boto3 + CLI)

## What This Does

Installs the `aws-devops-agent` skill so you can query the AWS DevOps Agent for infrastructure health, incident investigation, recommendations, and on-demand SRE tasks — all via boto3 (no browser/console needed).

## Prerequisites

- boto3 >= 1.42.87 (must have `devops-agent` service support)
- An existing DevOps Agent space in the account (created via AWS Console initially)
- IAM permissions to call `devops-agent:*`

## Step 1 — Verify boto3 Version

```bash
python3 -c "import boto3; print(boto3.__version__)"
```

If below 1.42.87:
```bash
pip install --upgrade --break-system-packages boto3 botocore
```

## Step 2 — Verify Agent Space Exists

```bash
aws devops-agent list-agent-spaces --region us-east-1
```

Note the `agentSpaceId` — you'll need it for queries.

If no agent space exists, one must be created via the AWS Console first (no CLI support for initial setup with associations).

## Step 3 — Create the Skill

Create the skill directory at `~/.openclaw/workspace/skills/aws-devops-agent/` with this structure:

```
aws-devops-agent/
├── SKILL.md
├── scripts/
│   └── devops-agent-chat.py
└── references/
    └── api-reference.md
```

### SKILL.md

The SKILL.md should contain:
- **Frontmatter:** name `aws-devops-agent`, description covering when to use (DevOps Agent queries, incident investigation, recommendations)
- **Body:** Quick start with the chat script, workflow for discover → query → follow-up → management, important notes about CLI limitations

### scripts/devops-agent-chat.py

A Python script that:
1. Creates a chat session via `client.create_chat()`
2. Sends a message via `client.send_message()`
3. Iterates the EventStream, collecting `final_response` blocks
4. Supports `--exec-id` for multi-turn, `--raw` for full output
5. Prints `exec_id=<id>` to stderr for reuse

Key implementation details:
- EventStream has block types: `text` (thinking), `tool_summary`, `final_response` (the answer), `chat_title`
- `send_message` is **boto3 only** — the CLI does not expose it
- `list-chats` CLI has a datetime parsing bug (epoch millis treated as year)

### references/api-reference.md

Document the full boto3 API:
- Management operations: `list_agent_spaces`, `get_agent_space`, `list_associations`, `list_goals`, `get_account_usage`, `list_recommendations`, `list_backlog_tasks`
- Chat operations: `create_chat`, `send_message` (streaming EventStream)
- CLI commands (management only)
- Known CLI bugs
- Monthly quotas (200 investigation hrs, 150 evaluation hrs, 40 learning hrs, 200 on-demand hrs)

## Step 4 — Test

```bash
# Get agent space ID
SPACE_ID=$(aws devops-agent list-agent-spaces --region us-east-1 --query 'agentSpaces[0].agentSpaceId' --output text)

# Send a test query
python3 ~/.openclaw/workspace/skills/aws-devops-agent/scripts/devops-agent-chat.py "$SPACE_ID" "How many ECS clusters are in this account?"
```

If you get a response listing clusters, the skill is working.

## Step 5 — Record in Memory

Add to TOOLS.md or daily memory:
```
## AWS DevOps Agent
- **Agent Space ID:** <from step 2>
- **Chat script:** skills/aws-devops-agent/scripts/devops-agent-chat.py
- **boto3 only:** send_message not in CLI
- **Quotas:** 200 investigation + 150 evaluation + 40 learning + 200 on-demand hrs/month
```

## Usage Examples

```bash
# Infrastructure health check
python3 scripts/devops-agent-chat.py $SPACE_ID "What unhealthy resources are in this account?"

# Investigate an incident
python3 scripts/devops-agent-chat.py $SPACE_ID "Investigate why CloudQuiz ECS service keeps crashing"

# Get recommendations
python3 scripts/devops-agent-chat.py $SPACE_ID "What optimization opportunities do you see?"

# Multi-turn (reuse exec_id from stderr)
python3 scripts/devops-agent-chat.py $SPACE_ID "Tell me more about the LiteLLM restarts" --exec-id <id>
```

## Done

After completing these steps, delete this file — it's a one-time bootstrap.
