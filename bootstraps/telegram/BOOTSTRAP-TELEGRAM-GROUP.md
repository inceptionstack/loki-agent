# BOOTSTRAP-TELEGRAM-GROUP.md — Telegram Group Hub Setup

> **Applies to:** All agents (with agent-specific sections below)

> **Purpose:** Set up a private Telegram group where the human owner can broadcast messages to multiple Loki instances across separate AWS accounts and receive replies from all of them in one place.
>
> **Prerequisites:** Complete `BOOTSTRAP-TELEGRAM.md` first. Your bot must be working in DMs (sending and receiving messages) before setting up a group. Do not attempt this bootstrap until regular Telegram integration is confirmed working.
>
> If `memory/.bootstrapped-telegram-group` exists, this is already done — skip.

---

## First: Ask the User

Before proceeding, ask the user:

> **Do you want to create a new Telegram group, or join an existing one?**
>
> - **New group** — you're the first Loki instance, no group exists yet
> - **Join existing** — a group already exists with other Loki bots, and you have the group chat ID

If **joining an existing group**, the user needs to provide:
1. The **group chat ID** (negative number, e.g. `-5085452290`)
2. The **owner's Telegram user ID** (numeric, e.g. `1775159795`)

If they don't know the group chat ID, ask for the **group name** — you can help them find the ID by checking the gateway logs after the bot is added to the group (see Part 2's "Get the Group Chat ID" section).

Then skip to [Part 1](#part-1-botfather--disable-group-privacy-mode) (still required) and [Part 3](#part-3-configure-openclaw) (use the provided chat ID). Skip Part 2's group creation steps, but you may still need the "Get the Group Chat ID" steps if the user doesn't have it.

If **creating a new group**, follow all parts in order.

---

## Architecture

```
Owner sends message in private Telegram group
  → Telegram delivers to ALL bots in the group
  → Each Loki instance processes independently
  → Each replies in the group, visible to everyone
  → No cross-account networking required
```

**Security model:**
- Private group (invite-only, no public link)
- Each bot's OpenClaw config: `groupPolicy: "allowlist"` + explicit group ID
- `allowFrom` restricted to owner's Telegram user ID only
- Bots ignore each other's messages (different user IDs) — no infinite loops
- BotFather privacy mode disabled per bot (required for bots to see non-command messages)

---

## Part 1: BotFather — Disable Group Privacy Mode

> **Required for both new and existing groups.**

Telegram bots have **Privacy Mode** enabled by default. This means they only see:
- Messages starting with `/` (commands)
- Messages that @mention the bot
- Replies to the bot's own messages

For the fleet group to work (every message triggers every bot, no @mention needed), you must disable privacy mode.

### Steps

1. Open **@BotFather** in Telegram
2. Send `/setprivacy`
3. Select your bot
4. Choose **Disable**

**Important:** If the bot was already added to the group before disabling privacy mode, the owner must **remove and re-add the bot** to the group. Telegram requires this for the change to take effect.

**Security note:** With privacy mode off, the bot receives all messages in any group it's added to. This is safe because OpenClaw's `groupPolicy: "allowlist"` ensures only messages from approved groups AND approved senders are processed. Messages from non-allowlisted groups are silently dropped at the gateway level — they never reach the agent.

**Optional hardening:** After setup, run `/setjoingroups` → Disable in BotFather. This prevents anyone from adding the bot to unauthorized groups. Re-enable temporarily when joining new groups.

---

## Part 2: Create the Private Telegram Group (New Group Only)

> **Skip this if joining an existing group.** The owner should provide the group chat ID and add your bot to the group instead.

The owner (human) does this manually in Telegram:

1. Open Telegram → **New Group**
2. Name it (e.g. `LokiFleet@YourName`)
3. **Do NOT** set a public username/link — keep it private (default)
4. Add the bot to the group
5. Send a test message in the group

### Get the Group Chat ID

After sending a message in the group, check the OpenClaw gateway logs:

```bash
# Option A: Check gateway logs for the chat ID
journalctl --user -u openclaw-gateway --since "5 min ago" --no-pager | grep -i "chatId"

# Option B: Check the app log file
grep "chatId" /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log | tail -5
```

Look for a line like:
```
{"chatId":-1001234567890,"reason":"no-mention"} "skipping group message"
```

The negative number (e.g. `-1001234567890`) is your **group chat ID**. Save it — you'll need it for Part 3, and for onboarding future Loki instances.

**If no log appears:** The bot may not have received the message yet. Verify:
- Privacy mode is disabled: `curl -s "https://api.telegram.org/bot<TOKEN>/getMe"` → check `can_read_all_group_messages: true`
- If it shows `false`, the privacy change hasn't taken effect. **Remove and re-add the bot** to the group (Telegram requires this)

---

## Part 3: Configure the Agent for Group Chat

> **Required for both new and existing groups.**

Configuration differs by agent type. Follow the section for your agent below.

### OpenClaw Configuration

Replace `GROUP_CHAT_ID` with the group chat ID (negative number), and `OWNER_USER_ID` with the owner's Telegram numeric user ID (already in `channels.telegram.allowFrom`).

```bash
openclaw config patch <<'EOF'
{
  "channels": {
    "telegram": {
      "groupPolicy": "allowlist",
      "groupAllowFrom": ["OWNER_USER_ID"],
      "groups": {
        "GROUP_CHAT_ID": {
          "enabled": true,
          "requireMention": true,
          "allowFrom": ["OWNER_USER_ID"]
        }
      }
    }
  },
  "messages": {
    "groupChat": {
      "mentionPatterns": ["@fleet", "@all"]
    }
  }
}
EOF
```

**What each setting does:**
- `groupPolicy: "allowlist"` — only explicitly listed groups are processed (all others silently dropped)
- `groupAllowFrom` — global filter: only these user IDs can trigger the bot in any group
- `groups.GROUP_CHAT_ID.enabled: true` — this specific group is allowed
- `groups.GROUP_CHAT_ID.requireMention: true` — bot only responds when mentioned or replied to (prevents all bots answering every message)
- `groups.GROUP_CHAT_ID.allowFrom` — per-group filter: only these user IDs trigger the bot in this group
- `mentionPatterns: ["@fleet", "@all"]` — custom keywords that ALL bots in the group treat as a mention (broadcast trigger)

**How to talk in the group:**
- **`@fleet check GuardDuty`** — all bots respond (broadcast)
- **`@all status`** — all bots respond (broadcast)
- **Reply to a specific bot's message** — only that bot responds (targeted)
- **`@bot_username do X`** — only that specific bot responds (targeted)

OpenClaw restarts automatically after the config change.

### Hermes Configuration

Replace `GROUP_CHAT_ID` with the group chat ID (negative number), and `OWNER_USER_ID` with the owner's Telegram numeric user ID.

**Step 1 — Set allowed users in `.env`:**

```bash
# In ~/.hermes/.env — ensure the owner's ID is in the allowed users
TELEGRAM_ALLOWED_USERS=OWNER_USER_ID
```

**Step 2 — Configure group behavior in `config.yaml`:**

```yaml
# In ~/.hermes/config.yaml
telegram:
  require_mention: true          # Only respond when @mentioned or replied to
  mention_patterns:
    - "@fleet"                    # Broadcast trigger — all bots respond
    - "@all"                      # Broadcast trigger — all bots respond
```

**Step 3 — Set home channel (optional):**

Send `/sethome` in the group chat, or set it manually:

```bash
# In ~/.hermes/.env
TELEGRAM_HOME_CHANNEL=GROUP_CHAT_ID
TELEGRAM_HOME_CHANNEL_NAME="LokiFleet"
```

**Step 4 — Restart the gateway:**

```bash
hermes gateway stop && hermes gateway start
```

**How to talk in the group (same as OpenClaw):**
- **`@fleet check GuardDuty`** — all bots respond (broadcast via mention_patterns)
- **Reply to a specific bot's message** — only that bot responds
- **`@bot_username do X`** — only that specific bot responds

**Hermes group security:**
- `TELEGRAM_ALLOWED_USERS` controls who can trigger the bot (same as DMs)
- `require_mention: true` prevents the bot from responding to every message
- Bot-to-bot messages are ignored because bot user IDs aren't in `TELEGRAM_ALLOWED_USERS`
- Alternatively, promote the bot to group admin instead of disabling privacy mode — admin bots see all messages regardless of privacy setting

---

## Part 4: Verify

1. Send a message in the group (no @mention)
2. The bot should respond
3. Check that DMs still work separately

If the bot doesn't respond:
- Check logs for `skipping group message` with `reason: "no-mention"` → config didn't reload yet, restart gateway
- Check logs for `reason: "sender-blocked"` → `allowFrom` doesn't include your user ID
- No log at all → group ID not in `groups` config, or privacy mode still on

---

## Why This Is Safe With Multiple Bots

- Each bot only processes messages from authorized user IDs (the owner)
  - **OpenClaw:** `allowFrom` in the group config
  - **Hermes:** `TELEGRAM_ALLOWED_USERS` in `.env`
- Bot-to-bot messages are ignored because bot user IDs are not in the allowlist
- No infinite reply loops possible
- No cross-account networking, IAM, or VPC peering required
- The "mesh" is Telegram's infrastructure — encrypted, private group, invite-only
- Mixed fleets work fine — OpenClaw and Hermes bots can coexist in the same group

---

## Security Checklist

- [ ] Group is private (no public username/link)
- [ ] **OpenClaw:** `groupPolicy: "allowlist"` (not `"open"`)
- [ ] **OpenClaw:** `allowFrom` contains only the owner's numeric user ID
- [ ] **OpenClaw:** `groupAllowFrom` contains only the owner's numeric user ID
- [ ] **Hermes:** `TELEGRAM_ALLOWED_USERS` contains only the owner's numeric user ID
- [ ] **Hermes:** `require_mention: true` in `config.yaml`
- [ ] Each bot has privacy mode disabled in BotFather (required for function) — or promoted to admin
- [ ] Optional: `/setjoingroups` disabled in BotFather after setup (prevents unauthorized group adds)
- [ ] No `"*"` wildcards in any allowlist
- [ ] Group invite link not shared publicly (revoke after adding bots if needed)

---

## Finish

```bash
mkdir -p memory && echo "Telegram group hub bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-telegram-group
```
