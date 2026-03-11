# BOOTSTRAP-TELEGRAM.md — Telegram Setup + Communication Rules

> **Part 1** (setup) runs once. **Part 2** (formatting rules) applies permanently to every message.
> If `memory/.bootstrapped-telegram` exists, Part 1 is done — skip to Part 2 to refresh the rules.

---

## Part 1: Set Up Telegram

### Step 1: Create a Telegram Bot

1. Open Telegram and search for **@BotFather**
2. Send `/newbot`
3. Choose a name (e.g. `Loki FastStart`)
4. Choose a username (must end in `bot`, e.g. `lokifaststart_bot`)
5. BotFather replies with your **bot token** — looks like `123456789:AAF...`

Store it immediately in Secrets Manager — don't leave it in chat history:

```bash
aws secretsmanager create-secret \
  --name /faststart/telegram-bot-token \
  --secret-string "YOUR_BOT_TOKEN_HERE" \
  --region us-east-1
```

### Step 2: Get Your Telegram Chat ID

Start a conversation with your new bot (send it any message). Then fetch your chat ID:

```bash
BOT_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id /faststart/telegram-bot-token \
  --query SecretString --output text --region us-east-1)

curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" \
  | python3 -c "import sys,json; updates=json.load(sys.stdin).get('result',[]); \
    [print(f'Chat ID: {u[\"message\"][\"chat\"][\"id\"]}  From: {u[\"message\"][\"from\"].get(\"username\",\"?\")}') for u in updates if 'message' in u]"
```

Note your **numeric chat ID** (e.g. `123456789`).

### Step 3: Configure OpenClaw

Add the Telegram channel to OpenClaw config. Ask Loki to run:

```
/config patch channels.telegram with:
  enabled: true
  botToken: <fetched from /faststart/telegram-bot-token>
  dmPolicy: allowlist
  allowFrom: [YOUR_CHAT_ID]
  groupPolicy: allowlist
  streaming: partial
```

Or use `openclaw config patch` directly:

```bash
BOT_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id /faststart/telegram-bot-token \
  --query SecretString --output text --region us-east-1)

openclaw config patch <<EOF
{
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "${BOT_TOKEN}",
      "dmPolicy": "allowlist",
      "allowFrom": ["YOUR_CHAT_ID"],
      "groupPolicy": "allowlist",
      "streaming": "partial"
    }
  },
  "plugins": {
    "entries": {
      "telegram": { "enabled": true }
    }
  }
}
EOF
```

OpenClaw restarts automatically after the config change.

### Step 4: Verify

Send your bot a message. You should get a response from Loki within a few seconds.

```bash
# Test the bot directly
BOT_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id /faststart/telegram-bot-token \
  --query SecretString --output text --region us-east-1)

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="YOUR_CHAT_ID" \
  -d text="Hello from Loki setup test" \
  -d parse_mode="HTML"
```

### Step 5: Security — allowlist only

The config above uses `dmPolicy: allowlist` — Loki only responds to chat IDs in `allowFrom`. Never set `dmPolicy: all` on a production instance. Anyone who finds your bot could interact with your agent.

To add more users:
```bash
openclaw config patch '{"channels":{"telegram":{"allowFrom":["CHAT_ID_1","CHAT_ID_2"]}}}'
```

---

## Part 2: Formatting Rules (Permanent)

Telegram renders markdown differently from most surfaces. These rules prevent broken messages.

### NEVER use

- **Markdown tables** — Telegram renders them as raw pipe characters `| col | col |`
- **Markdown headers** (`# H1`, `## H2`) — don't render as headers, show as `# text`
- **Bare absolute media paths** (`MEDIA:/home/...`) — blocked for security

### ALWAYS use instead

**Tables → bullet lists with bold labels:**

❌ Wrong:
```
| Model | Dims | Speed |
|-------|------|-------|
| Titan | 1024 | Fast  |
```

✅ Right:
```
• **Titan Embed V2** — 1024 dims, fastest
• **Cohere Embed v4** — 1536 dims, best quality
```

**Headers → bold or CAPS:**

❌ Wrong: `## Summary`
✅ Right: `**Summary**` or `SUMMARY`

### Links — suppress embeds

Wrap multiple links in `<>` to prevent Telegram from generating large previews:

```
<https://github.com/inceptionstack/embedrock>
<https://github.com/inceptionstack/loki-bootstrap>
```

Single important links can be left unwrapped if the preview is useful.

### Inline buttons for actions

Use inline buttons for confirmations and quick actions — Telegram renders them natively:

```
Ask Loki to send buttons like:
  "Deploy to prod?" [Yes, deploy ✅] [Cancel ❌]
```

The OpenClaw `message` tool supports this via `buttons`:
```json
buttons: [[
  {"text": "Yes, deploy", "callback_data": "deploy_yes", "style": "success"},
  {"text": "Cancel",      "callback_data": "deploy_no",  "style": "danger"}
]]
```

Use these for:
- Destructive operations (deletes, deploys, SCP changes)
- Yes/no confirmations before long-running tasks

### Reactions

Reactions are available but use them sparingly — at most 1 per 5–10 exchanges. Only react when it genuinely adds signal (acknowledging something important, expressing real appreciation). Don't react to every message.

---

## Add to SOUL.md or AGENTS.md

```markdown
## Platform Formatting
- **Telegram:** No markdown tables — use bullet lists. No headers — use **bold** or CAPS.
- Wrap multiple links in `<>` to suppress embeds.
- Use inline buttons for destructive operation confirmations.
```

---

## Finish

```bash
mkdir -p memory && echo "Telegram bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-telegram
```
