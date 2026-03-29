# BOOTSTRAP-TELEGRAM-GROUP.md — Telegram Group Hub Setup

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

Then skip to [Part 1](#part-1-botfather--disable-group-privacy-mode) (still required) and [Part 3](#part-3-configure-openclaw) (use the provided chat ID). Skip Part 2 entirely.

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

## Part 3: Configure OpenClaw

> **Required for both new and existing groups.**

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
          "requireMention": false,
          "allowFrom": ["OWNER_USER_ID"]
        }
      }
    }
  }
}
EOF
```

**What each setting does:**
- `groupPolicy: "allowlist"` — only explicitly listed groups are processed (all others silently dropped)
- `groupAllowFrom` — global filter: only these user IDs can trigger the bot in any group
- `groups.GROUP_CHAT_ID.enabled: true` — this specific group is allowed
- `groups.GROUP_CHAT_ID.requireMention: false` — bot responds to every message (no @mention needed). This is what makes broadcast work.
- `groups.GROUP_CHAT_ID.allowFrom` — per-group filter: only these user IDs trigger the bot in this group

OpenClaw restarts automatically after the config change.

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

- Each bot only processes messages from `allowFrom` user IDs (the owner)
- Bot-to-bot messages are ignored because bot user IDs are not in `allowFrom`
- No infinite reply loops possible
- No cross-account networking, IAM, or VPC peering required
- The "mesh" is Telegram's infrastructure — encrypted, private group, invite-only

---

## Security Checklist

- [ ] Group is private (no public username/link)
- [ ] `groupPolicy: "allowlist"` (not `"open"`)
- [ ] `allowFrom` contains only the owner's numeric user ID
- [ ] `groupAllowFrom` contains only the owner's numeric user ID
- [ ] Each bot has privacy mode disabled in BotFather (required for function)
- [ ] Optional: `/setjoingroups` disabled in BotFather after setup (prevents unauthorized group adds)
- [ ] No `"*"` wildcards in any `allowFrom` or `groupAllowFrom`
- [ ] Group invite link not shared publicly (revoke after adding bots if needed)

---

## Finish

```bash
mkdir -p memory && echo "Telegram group hub bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-telegram-group
```
