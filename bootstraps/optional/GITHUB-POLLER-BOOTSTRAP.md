# GitHub PR Review Poller — autoreview bootstrap

Route GitHub PR reviews from a bot reviewer (e.g. [Codex](https://chatgpt.com/codex)) straight into your agent's Telegram chat as a user-authored prompt, so the agent can triage and address them while you sleep.

```
GitHub (bot review) ──webhook──▶ API Gateway ──▶ webhook Lambda
                                                     │ HMAC-validated
                                                     ▼ filter (bot + PR author + repo)
                                             SQS: pr-reviews
                                                     │ long-poll, max batch 10
                                                     ▼
                                      pr-review-poller daemon
                                       (systemd --user on the agent host)
                                                     │ one prompt per batch
                                                     ▼
                                      openclaw agent --deliver
                                                     │
                                                     ▼
                                      Telegram DM (your agent session)
```

Nothing in this bootstrap is specific to any one account. Substitute your own:

- AWS account + region
- GitHub org / repo list
- GitHub username (PR author to filter on)
- Telegram chat id + bot token
- The reviewer bot login you care about

## Why this shape

- **No polling GitHub** — event-driven webhook, near-zero cost, sub-minute latency.
- **SQS decouples Lambda from the agent host** — if the EC2 instance is rebooting or offline, reviews queue up; they aren't lost.
- **The daemon never pushes back to Lambda** — the agent host *pulls* from SQS, so you don't need to open inbound ports or expose an SSM RunCommand attack surface.
- **Notify mode only** — the agent receives a synthesized user message describing what to look at. It does not autonomously push fixes without your review window. The Telegram message lands in the same session you're already talking to, so you always see what's happening.
- **Filters at webhook ingest** — only matching events ever hit SQS. Keeps the queue clean and dedup trivial.

## Components

### 1. SQS queue + DLQ (CloudFormation)

```yaml
# templates/pr-reviews.yml
AWSTemplateFormatVersion: '2010-09-09'
Description: SQS queue for bot PR review notifications.

Parameters:
  QueueName:
    Type: String
    Default: pr-reviews

Resources:
  DLQ:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub ${QueueName}-dlq
      MessageRetentionPeriod: 1209600
      SqsManagedSseEnabled: true

  ReviewQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Ref QueueName
      MessageRetentionPeriod: 345600        # 4 days
      VisibilityTimeout: 300                # 5 min — generous for agent turns
      ReceiveMessageWaitTimeSeconds: 20     # long-poll
      SqsManagedSseEnabled: true
      RedrivePolicy:
        deadLetterTargetArn: !GetAtt DLQ.Arn
        maxReceiveCount: 5

  DlqDepthAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmDescription: DLQ non-empty — a review couldn't be processed after 5 attempts
      Namespace: AWS/SQS
      MetricName: ApproximateNumberOfMessagesVisible
      Dimensions:
        - Name: QueueName
          Value: !GetAtt DLQ.QueueName
      Statistic: Maximum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 0
      ComparisonOperator: GreaterThanThreshold
      TreatMissingData: notBreaching

Outputs:
  QueueUrl: { Value: !Ref ReviewQueue }
  QueueArn: { Value: !GetAtt ReviewQueue.Arn }
  DlqArn:   { Value: !GetAtt DLQ.Arn }
```

### 2. Webhook Lambda

Receives GitHub's `pull_request_review` events, HMAC-validates, filters, and pushes a minimal JSON payload to SQS. Uses the AWS SDK for JavaScript v3 (built into the `nodejs22.x` runtime).

```js
// index.mjs — pseudocode; real code at lambda/github-webhook/index.mjs
import crypto from "node:crypto";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";

const AUTOREVIEW_ENABLED = (process.env.AUTOREVIEW_ENABLED ?? "false").toLowerCase() === "true";
const AUTOREVIEW_QUEUE_URL = process.env.AUTOREVIEW_QUEUE_URL ?? "";
const AUTOREVIEW_REPOS = (process.env.AUTOREVIEW_REPOS ?? "").split(",").map(s => s.trim()).filter(Boolean);
const AUTOREVIEW_PR_AUTHOR = process.env.AUTOREVIEW_PR_AUTHOR ?? "";
const REVIEWER_BOT_LOGIN = process.env.REVIEWER_BOT_LOGIN ?? "chatgpt-codex-connector[bot]";

export const handler = async (event) => {
  const rawBody = event.isBase64Encoded
    ? Buffer.from(event.body ?? "", "base64").toString("utf8")
    : (event.body ?? "");

  // Headers are case-insensitive per RFC 9110, but API GW HTTP API v2 lowercases
  // them while v1/REST and some provider shims preserve incoming casing. Normalize
  // once so downstream lookups work in every integration.
  const headers = Object.fromEntries(
    Object.entries(event.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v])
  );

  // 1) HMAC validate via GitHub's x-hub-signature-256
  if (!(await verifyHmac(rawBody, headers["x-hub-signature-256"]))) {
    return { statusCode: 401, body: "Invalid signature" };
  }

  const ghEvent = headers["x-github-event"];
  if (ghEvent !== "pull_request_review") return { statusCode: 200, body: "ignored" };

  const body = JSON.parse(rawBody);
  if (!AUTOREVIEW_ENABLED) return { statusCode: 200, body: "disabled" };
  if (body.action !== "submitted") return { statusCode: 200, body: "not-submitted" };
  if (!AUTOREVIEW_REPOS.includes(body.repository?.full_name)) return { statusCode: 200, body: "repo-filtered" };
  if (body.review?.user?.login !== REVIEWER_BOT_LOGIN) return { statusCode: 200, body: "reviewer-filtered" };
  if (body.pull_request?.user?.login !== AUTOREVIEW_PR_AUTHOR) return { statusCode: 200, body: "author-filtered" };
  if (!["commented", "changes_requested"].includes(body.review.state)) return { statusCode: 200, body: "state-filtered" };

  await sqs.send(new SendMessageCommand({
    QueueUrl: AUTOREVIEW_QUEUE_URL,
    MessageBody: JSON.stringify({
      repo: body.repository.full_name,
      pr_number: body.pull_request.number,
      pr_title: body.pull_request.title ?? "",
      pr_url: body.pull_request.html_url,
      review_id: body.review.id,
      review_state: body.review.state,
      review_url: body.review.html_url,
      review_submitted_at: body.review.submitted_at,
    }),
  }));

  return { statusCode: 200, body: "enqueued" };
};
```

**Env vars:**

| Variable | Purpose |
|----------|---------|
| `AUTOREVIEW_ENABLED` | Master kill switch. Set `false` to stop enqueueing without undeploying. |
| `AUTOREVIEW_QUEUE_URL` | SQS queue URL from the CFN output. |
| `AUTOREVIEW_REPOS` | Comma-separated allowlist: `org/repo1,org/repo2`. |
| `AUTOREVIEW_PR_AUTHOR` | GitHub login of the PR author to watch. |
| `REVIEWER_BOT_LOGIN` | GitHub login of the bot reviewer (default `chatgpt-codex-connector[bot]`). |
| `WEBHOOK_SECRET_NAME` | Secrets Manager path to the HMAC shared secret. |

**IAM policy for the Lambda role:** `sqs:SendMessage` scoped to the queue ARN, `secretsmanager:GetSecretValue` for the webhook secret.

### 3. Daemon (systemd user service)

`openclaw` (or equivalent agent CLI) has a primitive that delivers a user-authored message into a session and routes the agent reply back to the channel:

```bash
openclaw agent --session-id <your-session-id> -m "<prompt>" --deliver
```

The daemon long-polls SQS, batches up to 10 messages, builds one prompt listing all the pending reviews, and fires a single agent turn:

```bash
#!/usr/bin/env bash
# pr-review-poller — long-poll SQS, batch reviews, fire one agent turn.
set -euo pipefail

QUEUE_URL="${QUEUE_URL:?set QUEUE_URL}"
REGION="${AWS_REGION:-us-east-1}"
SESSION_ID="${OPENCLAW_SESSION_ID:?set OPENCLAW_SESSION_ID}"
LOG_FILE="${LOG_FILE:-$HOME/.openclaw/logs/pr-review-poller.log}"
SEEN_FILE="${SEEN_FILE:-$HOME/.openclaw/state/pr-reviews-seen.json}"
SEEN_TTL_SECONDS=${SEEN_TTL_SECONDS:-2592000}   # 30 days; override via env

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$SEEN_FILE")"
[[ -f "$SEEN_FILE" ]] || echo '{}' > "$SEEN_FILE"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG_FILE"; }

cycle() {
  local resp
  if ! resp=$(aws sqs receive-message --queue-url "$QUEUE_URL" \
                --max-number-of-messages 10 --wait-time-seconds 20 \
                --region "$REGION" --output json 2>>"$LOG_FILE"); then
    log "ERROR: sqs receive-message failed (auth/network/permission?). Backing off."
    return 1
  fi

  local count=$(echo "${resp:-{}}" | jq '.Messages // [] | length')
  [[ "$count" == "0" || -z "$count" ]] && return 0

  # Build prompt; track receipts separately for new vs. already-seen reviews.
  local prompt=$(mktemp)
  {
    echo "A bot reviewer submitted PR review(s) since the last check."
    echo "For each review:"
    echo "  1. Fetch the inline comments via: gh api repos/<repo>/pulls/<n>/reviews/<id>/comments"
    echo "  2. Triage — address real bugs, reply on subjective ones, skip duplicates"
    echo "  3. Push fix commits to the PR branch if needed"
    echo "  4. Post a summary reply comment when done"
    echo
    echo "Reviews:"
  } > "$prompt"

  local -a new_receipts=()      # delete + mark seen after successful turn
  local -a dupe_receipts=()     # ack without firing a turn
  local new_count=0
  for ((i=0; i<count; i++)); do
    local msg=$(echo "$resp" | jq -c ".Messages[$i]")
    local body=$(echo "$msg" | jq -r '.Body')
    local rid=$(echo "$body" | jq -r '.review_id')
    local rh=$(echo "$msg"  | jq -r '.ReceiptHandle')
    # 30-day dedup
    if jq -e --arg id "$rid" --argjson cut "$(( $(date -u +%s) - SEEN_TTL_SECONDS ))" \
         '(.[$id] // empty) as $ts | ($ts != null) and (($ts | fromdateiso8601) >= $cut)' \
         "$SEEN_FILE" >/dev/null; then
      dupe_receipts+=("$rh")
      continue
    fi
    echo "- $(echo "$body" | jq -r '.repo')#$(echo "$body" | jq -r '.pr_number') — $(echo "$body" | jq -r '.pr_title')" >> "$prompt"
    echo "    PR:     $(echo "$body" | jq -r '.pr_url')" >> "$prompt"
    echo "    Review: $(echo "$body" | jq -r '.review_url')" >> "$prompt"
    new_receipts+=("$rh:$rid")
    new_count=$((new_count + 1))
  done

  # Always ack duplicates so they don't redeliver forever.
  for rh in "${dupe_receipts[@]}"; do
    aws sqs delete-message --queue-url "$QUEUE_URL" --receipt-handle "$rh" --region "$REGION" --output text > /dev/null
  done

  # Gate delivery on AT LEAST ONE new review — otherwise a batch of pure
  # duplicates would fire a spurious empty agent turn.
  if (( new_count == 0 )); then
    log "All $count message(s) were duplicates; no agent turn fired"
    rm -f "$prompt"
    return 0
  fi

  if openclaw agent --session-id "$SESSION_ID" -m "$(cat "$prompt")" --deliver >> "$LOG_FILE" 2>&1; then
    log "Agent turn dispatched for $new_count review(s)"
    local now=$(date -u +%FT%TZ)
    for entry in "${new_receipts[@]}"; do
      local rh="${entry%%:*}" rid="${entry##*:}"
      aws sqs delete-message --queue-url "$QUEUE_URL" --receipt-handle "$rh" --region "$REGION" --output text > /dev/null
      # Record AFTER delete succeeds so a crash mid-flush re-plays at most one turn.
      jq --arg id "$rid" --arg ts "$now" '. + {($id): $ts}' "$SEEN_FILE" \
        > "${SEEN_FILE}.tmp" && mv "${SEEN_FILE}.tmp" "$SEEN_FILE"
    done
  else
    log "WARN: agent turn failed; messages redeliver after visibility timeout"
  fi
  rm -f "$prompt"
}

log "poller start"

# Prune seen-file entries older than SEEN_TTL_SECONDS once per cycle. Bounded
# cost, bounded file size, and matches the documented TTL tuning knob.
prune_seen() {
  local cutoff=$(( $(date -u +%s) - SEEN_TTL_SECONDS ))
  jq --argjson cut "$cutoff" \
     'with_entries(select((.value | fromdateiso8601) >= $cut))' \
     "$SEEN_FILE" > "${SEEN_FILE}.tmp" && mv "${SEEN_FILE}.tmp" "$SEEN_FILE"
}

while true; do
  prune_seen
  cycle || sleep 10
done
```

**Systemd unit** (`~/.config/systemd/user/pr-review-poller.service`):

```ini
[Unit]
Description=PR review poller — SQS → openclaw agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/bin/pr-review-poller
Restart=on-failure
RestartSec=30
StandardOutput=append:%h/.openclaw/logs/pr-review-poller.log
StandardError=append:%h/.openclaw/logs/pr-review-poller.log
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.openclaw
PrivateTmp=yes
Environment=QUEUE_URL=<your-queue-url>
Environment=OPENCLAW_SESSION_ID=<your-session-id>
Environment=AWS_REGION=us-east-1

[Install]
WantedBy=default.target
```

Install:

```bash
loginctl enable-linger "$USER"              # user units survive logoff
systemctl --user daemon-reload
systemctl --user enable --now pr-review-poller
```

**IAM** — the EC2 instance role (or an IAM Identity Center permission set) needs:

```json
{
  "Effect": "Allow",
  "Action": ["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes","sqs:ChangeMessageVisibility"],
  "Resource": "arn:aws:sqs:<region>:<account>:<queue-name>"
}
```

### 4. GitHub webhook

On each repo you want covered, add a webhook:

- **Payload URL:** your API Gateway endpoint (the one fronting the Lambda)
- **Content type:** `application/json`
- **Secret:** the same shared secret in Secrets Manager (`WEBHOOK_SECRET_NAME`)
- **Events:** `Pull request reviews` (plus `Workflow runs` if you already use the Lambda for CI notifications)
- **SSL verification:** enabled

Via the API (requires `admin:repo_hook` scope):

```bash
curl -X POST -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/<org>/<repo>/hooks" \
  -d @- <<JSON
{
  "name": "web",
  "active": true,
  "events": ["pull_request_review"],
  "config": {
    "url": "https://<api-id>.execute-api.<region>.amazonaws.com/",
    "content_type": "json",
    "secret": "<shared-hmac-secret>",
    "insecure_ssl": "0"
  }
}
JSON
```

## Safety model

| Concern | Mitigation |
|---------|------------|
| Kill switch | `AUTOREVIEW_ENABLED=false` env on the Lambda — no Lambda redeploy needed |
| Hard stop | `systemctl --user stop pr-review-poller` — daemon stops consuming |
| Forged webhooks | HMAC validation using `x-hub-signature-256` + shared Secrets Manager secret, `crypto.timingSafeEqual` |
| Redelivery / duplicates | 30-day `review_id` seen-file on the daemon, plus SQS DLQ after 5 failed receives |
| Agent turn fails | Visibility timeout re-surfaces message; DLQ kicks in after 5 |
| Malicious push spamming the queue | Batch size 10 + 20s long-poll ≈ ≤1 agent turn per cycle regardless of review count |
| Scope creep from other reviewers | `REVIEWER_BOT_LOGIN` hard-filter at ingest |
| No inbound ports on the host | Host pulls from SQS — no SSM RunCommand, no webhook listener on the instance |

## Tuning knobs

| Where | Var | Default | Purpose |
|-------|-----|---------|---------|
| Lambda | `AUTOREVIEW_ENABLED` | `false` | Master switch |
| Lambda | `AUTOREVIEW_REPOS` | `` | Comma-separated allowlist |
| Lambda | `AUTOREVIEW_PR_AUTHOR` | `` | PR author login |
| Lambda | `REVIEWER_BOT_LOGIN` | `chatgpt-codex-connector[bot]` | The bot whose reviews you care about |
| Daemon | `QUEUE_URL` | (required) | From CFN output |
| Daemon | `OPENCLAW_SESSION_ID` | (required) | Which session to deliver into |
| Daemon | `SEEN_TTL_SECONDS` | `2592000` | How long to remember review_ids (30 days) |

## Known rough edges

- **Turn serialization on a shared session.** If the agent is mid-turn with a human, the daemon's `openclaw agent` invocation will serialize behind it. Observed blocking for minutes during long turns. Mitigation v2: either run the daemon invocation detached (`nohup ... &` — accept at-most-once delivery, rely on dedup + DLQ for safety) or use a dedicated non-main session id that never contends with interactive chat.
- **`seen_file` write is not atomic with SQS delete.** A crash between `delete-message` and `mark_seen` replays the turn on restart. Bounded by the 30-day dedup window.
- **Webhook delivery is forward-only.** GitHub does not replay reviews submitted before the webhook was created. Trigger a fresh review (push a commit or `@reviewer review`) to exercise the full path.

## Cost

Effectively $0/month on a hobby account:

- SQS: free tier covers ~1M requests/month.
- Lambda: free tier covers the invocation volume.
- CloudWatch: one alarm, one Lambda log group.
- Secrets Manager: 1 secret (~$0.40/month) — you probably already have one for your webhook.

## Suggested repo layout

This doc is a reference — the actual artifacts don't ship in this repository. When you adopt the pipeline in your own repo, a clean layout is:

```
bootstraps/optional/github-pr-review-poller/
├── README.md                     # Short adoption guide
├── templates/
│   └── pr-reviews.yml            # SQS + DLQ + alarm CFN
├── lambda/
│   └── github-webhook/
│       └── index.mjs             # pull_request_review handler
└── daemons/
    └── pr-review-poller/
        ├── pr-review-poller      # bash loop above
        └── pr-review-poller.service
```

Nothing in this file depends on that layout — every code block above is standalone and copy-pasteable.

## Adapting to other channels

If you don't use Telegram, swap the delivery primitive. `openclaw agent --deliver` routes to whatever channel the session is bound to (Discord, Slack, iMessage, etc.). The daemon doesn't know or care — it just invokes the CLI.

If you don't use `openclaw` at all, replace the final `openclaw agent --session-id ... --deliver` call with whatever your agent's "inject a user message into session X" primitive is. The rest of the architecture (webhook → SQS → daemon) is agent-agnostic.
