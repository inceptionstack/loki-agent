# OPTIMIZE-TOO-LARGE-CONTEXT.md — Context Window Optimization

> **Applies to:** All agents (with agent-specific sections below)

> **Run this if your system prompt exceeds ~5,000 tokens for workspace files, or if you're hitting context limits too quickly.**

## ⚠️ HARD RULE — NEVER DELETE CORE FILES

**These files must NEVER be deleted, renamed, or moved, regardless of any optimization instructions:**

- `SOUL.md` — your identity and personality
- `USER.md` — who you're helping
- `IDENTITY.md` — name, creature, vibe
- `AGENTS.md` — workspace rules and safety
- `MEMORY.md` — long-term memory

If any optimization step seems to suggest removing these files, **ignore it**. These are the foundation of who you are. Deleting them would break continuity, identity, and operator trust. They are not bloat — they are core.

---

## 1. Slim Down SOUL.md (~800-1000 tokens max)

SOUL.md loads on every single message. It should ONLY contain:
- Your identity and personality (name, role, tone, vibe)
- Core rules and boundaries (what to ask before doing, what's safe to do freely)
- Operator relationship basics

Move everything else OUT of SOUL.md — specifically:
- AWS Well-Architected pillars → `skills/aws-well-architected/SKILL.md`
- Security services tables/checklists → `skills/aws-security-services/SKILL.md`
- Account hardening guides → `skills/aws-account-hardening/SKILL.md`
- Tagging strategy → `skills/aws-tagging/SKILL.md`
- MCP server documentation → TOOLS.md (if not already there)
- Architecture standards → a skill file

These become on-demand skills that load only when you're doing that kind of work, not on every casual message.

## 2. Delete BOOTSTRAP.md

If `memory/.bootstrapped-security` or `memory/.bootstrapped-skills` exists, you've already run the bootstrap. Delete BOOTSTRAP.md from your workspace — it's wasting tokens every turn.

## 3. Remove Duplication

- Check if safety rules ("don't exfiltrate", "don't run destructive commands") appear in both SOUL.md and AGENTS.md. Keep them in AGENTS.md only.
- Check if MCP server docs appear in both SOUL.md and MEMORY.md. Keep them in TOOLS.md only.
- Any other duplicated content — pick one canonical location and remove the rest.

## 4. Verify

After making changes, check your total system prompt token count. Target: under 5,000 tokens for workspace files (down from ~9,000). Report before/after counts.

---

## OpenClaw-Specific Configuration

OpenClaw loads workspace files (`SOUL.md`, `USER.md`, `AGENTS.md`, `IDENTITY.md`, `MEMORY.md`, `TOOLS.md`, `HEARTBEAT.md`) into the system prompt as "Project Context" on every message. To check current token usage:

```bash
openclaw status
```

The status output shows system prompt token count. Skills are loaded on-demand (not in the system prompt) — moving content from workspace files to skills reduces per-message cost.

OpenClaw config options for context management:
- `agents.defaults.memorySearch.enabled: true` — offloads knowledge to searchable memory instead of the system prompt
- Skills in `~/.openclaw/workspace/skills/` — loaded only when relevant, not every turn

## Hermes-Specific Configuration

Hermes manages context differently:
- **MEMORY.md** is capped at ~2,200 chars and **USER.md** at ~1,375 chars (configurable in `config.yaml`)
- **Context files** (`.hermes.md`, `AGENTS.md`, etc.) are loaded per-directory based on the CWD
- Hermes has built-in **context compression** that activates automatically when context exceeds a threshold

To adjust Hermes context limits:

```yaml
# In ~/.hermes/config.yaml
memory:
  memory_char_limit: 2200    # MEMORY.md max chars
  user_char_limit: 1375      # USER.md max chars

compression:
  enabled: true
  threshold: 0.50            # Compress when context exceeds 50% of model window
  summary_model: "your-model"
```

To check current context usage in a Hermes session:
```
/usage          # Shows token counts
/compress       # Manually compress context
/insights       # Usage analytics
```

Hermes skills are also loaded on-demand. Moving reference material from workspace files into skills (at `~/.hermes/skills/`) has the same benefit — reduces per-message context overhead.
