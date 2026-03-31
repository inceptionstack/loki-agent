# BOOTSTRAP-PIPELINE-NOTIFICATIONS.md — Pipeline Notifications to Telegram + Agent

> **Applies to:** All agents (with agent-specific sections below)

> **Run this once to wire up build notifications.**
> If `memory/.bootstrapped-pipeline-notifications` exists, skip.

## Overview

Two independent notification pipelines, one for each source:

- **AWS CodePipeline** — EventBridge rule → Lambda → Telegram (HTML) + OpenClaw system event via SSM
- **GitHub Actions** — Webhook → API Gateway → Lambda → Telegram (HTML)

Both send to the operator's Telegram chat and inject a system event into the OpenClaw main session so Loki can react to build failures automatically.

---

## Part 1: CodePipeline Notifications

### Architecture

```
CodePipeline state change
  → EventBridge rule (STARTED / SUCCEEDED / FAILED / CANCELED)
    → Lambda (faststart-pipeline-notifier)
      → Telegram (HTML, with commit message)
      → openclaw system event via SSM RunCommand
```

### Step 1: Store Telegram bot token in Secrets Manager

```bash
aws secretsmanager create-secret \
  --name /faststart/telegram-bot-token \
  --secret-string "YOUR_BOT_TOKEN" \
  --region us-east-1
```

### Step 2: Deploy the notifier Lambda

Create `index.mjs`:

```javascript
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { CodePipelineClient, GetPipelineExecutionCommand } from "@aws-sdk/client-codepipeline";
import { SSMClient, SendCommandCommand } from "@aws-sdk/client-ssm";

const sm = new SecretsManagerClient({ region: "us-east-1" });
const cp = new CodePipelineClient({ region: "us-east-1" });
const ssm = new SSMClient({ region: "us-east-1" });

const CHAT_ID = process.env.TELEGRAM_CHAT_ID;
const SECRET_NAME = "/faststart/telegram-bot-token";
const INSTANCE_ID = process.env.OPENCLAW_INSTANCE_ID;

let cachedToken = null;
async function getBotToken() {
  if (cachedToken) return cachedToken;
  const resp = await sm.send(new GetSecretValueCommand({ SecretId: SECRET_NAME }));
  cachedToken = resp.SecretString;
  return cachedToken;
}

async function sendTelegram(text) {
  const token = await getBotToken();
  await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: CHAT_ID, text, parse_mode: "HTML", disable_web_page_preview: true })
  });
}

async function notifyOpenClaw(message) {
  try {
    await ssm.send(new SendCommandCommand({
      InstanceIds: [INSTANCE_ID],
      DocumentName: "AWS-RunShellScript",
      Parameters: {
        commands: [
          `runuser -u ec2-user -- bash -c 'export PATH="/home/ec2-user/.local/share/mise/shims:$PATH" && openclaw system event --text "${message.replace(/"/g, '\\"')}" --mode now'`
        ]
      },
      TimeoutSeconds: 15
    }));
  } catch (e) {
    console.warn("OpenClaw notify failed:", e.message);
  }
}

function statusEmoji(state) {
  return { STARTED: "🚀", SUCCEEDED: "✅", FAILED: "❌", CANCELED: "⏹️", SUPERSEDED: "⏭️" }[state] || "ℹ️";
}

export async function handler(event) {
  const detail = event.detail;
  const pipeline = detail.pipeline;
  const executionId = detail["execution-id"];
  const state = detail.state;
  const emoji = statusEmoji(state);
  const shortId = executionId.slice(0, 8);

  let commitMessages = [];
  try {
    const execution = await cp.send(new GetPipelineExecutionCommand({
      pipelineName: pipeline, pipelineExecutionId: executionId
    }));
    commitMessages = (execution.pipelineExecution?.artifactRevisions || [])
      .map(a => a.revisionSummary).filter(Boolean);
  } catch (e) {
    console.warn("Could not get commit info:", e.message);
  }

  const tgMsg = [
    `${emoji} <b>Pipeline: ${pipeline}</b>`,
    `Status: <b>${state}</b>`,
    `Execution: <code>${shortId}</code>`,
    commitMessages.length ? `\nCommits:\n${commitMessages.map(c => `• ${c}`).join("\n")}` : ""
  ].join("\n").trim();

  const ocMsg = `${emoji} Pipeline ${pipeline} — ${state} [${shortId}]` +
    (commitMessages.length ? `. Commits: ${commitMessages.join("; ")}` : "");

  await Promise.all([sendTelegram(tgMsg), notifyOpenClaw(ocMsg)]);
  return { statusCode: 200 };
}
```

Deploy it:

```bash
zip function.zip index.mjs

aws lambda create-function \
  --function-name faststart-pipeline-notifier \
  --runtime nodejs22.x \
  --handler index.handler \
  --role arn:aws:iam::ACCOUNT_ID:role/faststart-pipeline-notifier-role \
  --zip-file fileb://function.zip \
  --environment "Variables={TELEGRAM_CHAT_ID=YOUR_CHAT_ID,OPENCLAW_INSTANCE_ID=YOUR_INSTANCE_ID}" \
  --region us-east-1
```

### Step 3: IAM Role for the Lambda

The role needs:

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:us-east-1:ACCOUNT_ID:*"
    },
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:/faststart/telegram-bot-token-*"
    },
    {
      "Effect": "Allow",
      "Action": ["codepipeline:GetPipelineExecution", "codecommit:GetCommit", "codecommit:BatchGetCommits"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "arn:aws:ssm:us-east-1:*:document/AWS-RunShellScript",
        "arn:aws:ec2:us-east-1:ACCOUNT_ID:instance/YOUR_INSTANCE_ID"
      ]
    }
  ]
}
```

### Step 4: EventBridge Rule

```bash
# Create the rule
aws events put-rule \
  --name faststart-pipeline-notifications \
  --event-pattern '{
    "source": ["aws.codepipeline"],
    "detail-type": ["CodePipeline Pipeline Execution State Change"],
    "detail": { "state": ["STARTED", "SUCCEEDED", "FAILED", "CANCELED"] }
  }' \
  --state ENABLED \
  --region us-east-1

# Add Lambda as target (get Lambda ARN first)
LAMBDA_ARN=$(aws lambda get-function --function-name faststart-pipeline-notifier \
  --query 'Configuration.FunctionArn' --output text --region us-east-1)

aws events put-targets \
  --rule faststart-pipeline-notifications \
  --targets "Id=pipeline-notifier,Arn=${LAMBDA_ARN}" \
  --region us-east-1

# Allow EventBridge to invoke the Lambda
aws lambda add-permission \
  --function-name faststart-pipeline-notifier \
  --statement-id EventBridgePipelineNotifications \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --region us-east-1
```

---

## Part 2: GitHub Actions Notifications

### Architecture

```
GitHub workflow_run event (started / completed)
  → Repository webhook → API Gateway (HTTP API)
    → Lambda (inceptionstack-github-webhook)
      → Telegram (HTML, with branch + commit)
```

> **Note:** Lambda Function URLs are blocked by SCP in this org — use API Gateway instead.

> **⚠️ OSS Repos:** GitHub repos are assumed to be **open source**. Repo-level webhooks fire for ALL contributors — not just your team. The webhook Lambda **must** filter by author before sending notifications, otherwise every random fork PR or external contributor commit will ping your Telegram. Add an allowlist of GitHub usernames or org membership check inside the Lambda handler. See the filtering example below.
>
> **CodePipeline** (Part 1) does **not** have this problem — CodePipeline runs are internal to your AWS account and only trigger for commits that make it through your pipeline source configuration.

### Step 1: Deploy the webhook Lambda

Create `index.mjs`:

```javascript
import https from "node:https";

const BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const CHAT_ID = process.env.TELEGRAM_CHAT_ID;

function sendTelegram(text) {
  const body = JSON.stringify({ chat_id: CHAT_ID, text, parse_mode: "HTML" });
  return new Promise((resolve, reject) => {
    const req = https.request(
      `https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`,
      { method: "POST", headers: { "Content-Type": "application/json" } },
      (res) => { let d = ""; res.on("data", c => d += c); res.on("end", () => resolve(d)); }
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

export const handler = async (event) => {
  const ghEvent = event.headers?.["x-github-event"] || "unknown";
  let body;
  try { body = typeof event.body === "string" ? JSON.parse(event.body) : event.body; }
  catch { return { statusCode: 400, body: "Bad JSON" }; }

  let msg = null;

  if (ghEvent === "workflow_run") {
    const { action, workflow_run: wr, repository: repo } = body;

    // OSS filter: only notify for commits by allowed authors
    // Add your GitHub usernames here — external contributors are silently ignored
    const ALLOWED_AUTHORS = (process.env.ALLOWED_AUTHORS || "").split(",").map(s => s.trim().toLowerCase()).filter(Boolean);
    const author = (wr?.actor?.login || wr?.triggering_actor?.login || "").toLowerCase();
    if (ALLOWED_AUTHORS.length > 0 && !ALLOWED_AUTHORS.includes(author)) {
      return { statusCode: 200, body: "skipped — external contributor" };
    }

    const repoName = repo?.name || "unknown";
    const branch = wr?.head_branch || "?";
    const sha = wr?.head_sha?.slice(0, 7) || "?";
    const commitMsg = wr?.head_commit?.message?.split("\n")[0] || "no message";
    const url = wr?.html_url || "";

    if (action === "requested") {
      msg = `🔨 <b>${repoName}</b> — CI started\nBranch: <code>${branch}</code> (${sha})\nCommit: ${commitMsg}\n<a href="${url}">View run</a>`;
    } else if (action === "completed" && wr?.conclusion === "failure") {
      msg = `❌ <b>${repoName}</b> — CI FAILED\nBranch: <code>${branch}</code> (${sha})\nCommit: ${commitMsg}\n<a href="${url}">View run</a>`;
    } else if (action === "completed" && wr?.conclusion === "success") {
      msg = `✅ <b>${repoName}</b> — CI passed\nBranch: <code>${branch}</code> (${sha})\nCommit: ${commitMsg}`;
    }
  }

  if (msg) await sendTelegram(msg);
  return { statusCode: 200, body: "ok" };
};
```

Deploy:

```bash
zip function.zip index.mjs

aws lambda create-function \
  --function-name inceptionstack-github-webhook \
  --runtime nodejs22.x \
  --handler index.handler \
  --role arn:aws:iam::ACCOUNT_ID:role/github-webhook-lambda-role \
  --zip-file fileb://function.zip \
  --environment "Variables={TELEGRAM_BOT_TOKEN=YOUR_BOT_TOKEN,TELEGRAM_CHAT_ID=YOUR_CHAT_ID,ALLOWED_AUTHORS=your-github-username}" \
  --region us-east-1
```

> **Bot token directly in env** (not Secrets Manager) is fine here since GitHub sends unauthenticated webhooks anyway — there's no secret to protect.

### Step 2: Create API Gateway (HTTP API)

```bash
# Create the API
API_ID=$(aws apigatewayv2 create-api \
  --name inceptionstack-github-webhook \
  --protocol-type HTTP \
  --query 'ApiId' --output text --region us-east-1)

# Create Lambda integration
LAMBDA_ARN=$(aws lambda get-function --function-name inceptionstack-github-webhook \
  --query 'Configuration.FunctionArn' --output text --region us-east-1)

INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type AWS_PROXY \
  --integration-uri $LAMBDA_ARN \
  --payload-format-version 2.0 \
  --query 'IntegrationId' --output text --region us-east-1)

# Create route and deploy
aws apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key "POST /webhook" \
  --target "integrations/$INTEGRATION_ID" \
  --region us-east-1

aws apigatewayv2 create-stage \
  --api-id $API_ID \
  --stage-name '$default' \
  --auto-deploy \
  --region us-east-1

# Allow API Gateway to invoke Lambda
aws lambda add-permission \
  --function-name inceptionstack-github-webhook \
  --statement-id ApiGatewayWebhook \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --region us-east-1

# Get the webhook URL
echo "Webhook URL: https://${API_ID}.execute-api.us-east-1.amazonaws.com/webhook"
```

### Step 3: Register Webhook on Each GitHub Repo

> **Important:** Repos may already have webhooks registered by other systems (e.g. other notification pipelines, CI integrations). **Do not delete existing webhooks.** Always add your webhook alongside any that already exist. Check first, then add only if your URL isn't already registered.

```bash
export GH_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id /faststart/github-token --query SecretString --output text --region us-east-1)

WEBHOOK_URL="https://API_ID.execute-api.us-east-1.amazonaws.com/webhook"

for repo in admin-mission-control-ui solo-mission-control-ui standalone-remote-access-ui; do
  # Check if this webhook URL is already registered — don't duplicate
  existing=$(curl -s -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/inceptionstack/$repo/hooks" | \
    python3 -c "import sys,json; hooks=json.load(sys.stdin); print('yes' if any('$WEBHOOK_URL' in h.get('config',{}).get('url','') for h in hooks) else 'no')")

  if [ "$existing" = "yes" ]; then
    echo "$repo: webhook already registered, skipping"
    continue
  fi

  curl -s -X POST -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/inceptionstack/$repo/hooks" \
    -d "{\"name\":\"web\",\"active\":true,\"events\":[\"workflow_run\"],\"config\":{\"url\":\"$WEBHOOK_URL\",\"content_type\":\"json\"}}"
  echo "Webhook added: $repo"
done
```

---

## What Loki Does With Notifications

When a system event arrives (CodePipeline path), Loki receives it in the main session and should:

- **On FAILED:** Immediately check CodeBuild logs, identify the failure, fix the code, push, and wait for green. Alert the operator.
- **On SUCCEEDED:** Log it. If a task was in-progress waiting for pipeline green, move it to `done` and notify the operator.
- **On STARTED:** Log it silently.

GitHub webhook notifications go only to Telegram (no agent system event injection currently).

---

## Finish

```bash
mkdir -p memory && echo "Pipeline notifications bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-pipeline-notifications
```

---

## OpenClaw-Specific Configuration

The Lambda notifier injects system events into OpenClaw via SSM RunCommand:

```bash
runuser -u ec2-user -- bash -c 'openclaw system event --text "PIPELINE_MSG" --mode now'
```

This delivers the event to OpenClaw's main session, where the agent can auto-react to failures. The `notifyOpenClaw` function in the Lambda code (Part 1) handles this path.

## Hermes-Specific Configuration

Hermes receives notifications differently. Instead of SSM RunCommand to inject system events, use the Hermes gateway API or `hermes event` CLI:

**Option A — `hermes event` CLI via SSM:**

Replace the `notifyOpenClaw` function in the Lambda handler with:

```javascript
async function notifyHermes(message) {
  try {
    await ssm.send(new SendCommandCommand({
      InstanceIds: [INSTANCE_ID],
      DocumentName: "AWS-RunShellScript",
      Parameters: {
        commands: [
          `runuser -u ec2-user -- bash -c 'export PATH="/home/ec2-user/.local/bin:$PATH" && hermes event "${message.replace(/"/g, '\\"')}"'`
        ]
      },
      TimeoutSeconds: 15
    }));
  } catch (e) {
    console.warn("Hermes notify failed:", e.message);
  }
}
```

**Option B — Hermes gateway webhook:**

If the Hermes gateway exposes a webhook endpoint, POST events directly from the Lambda without SSM:

```javascript
await fetch('https://your-hermes-gateway/webhook', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ text: message })
});
```

Check Hermes docs for the webhook format: <https://hermes-agent.nousresearch.com/docs/user-guide/messaging/webhooks>
