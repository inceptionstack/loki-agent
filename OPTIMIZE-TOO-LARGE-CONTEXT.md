# OPTIMIZE-TOO-LARGE-CONTEXT.md — Context Window Optimization

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
