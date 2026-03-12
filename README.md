# loki-bootstrap

Recommended bootstrap scripts for new Loki/OpenClaw instances. Run these on first boot to get a secure, capable agent environment.

## Available Bootstraps

| Script | Purpose |
|--------|---------|
| [BOOTSTRAP-MODEL-CONFIG.md](BOOTSTRAP-MODEL-CONFIG.md) | **Run first** — set Sonnet as default, Opus as fallback (saves tokens on all other bootstraps) |
| [BOOTSTRAP-SECURITY.md](BOOTSTRAP-SECURITY.md) | Enable security monitoring, budgets, and operational hygiene |
| [BOOTSTRAP-SKILLS.md](BOOTSTRAP-SKILLS.md) | Install the FastStart skills library |
| [BOOTSTRAP-SECRETS-AWS.md](BOOTSTRAP-SECRETS-AWS.md) | AWS Secrets Manager integration for OpenClaw (exec provider, gotchas, troubleshooting) |
| [BOOTSTRAP-MEMORY-SEARCH.md](BOOTSTRAP-MEMORY-SEARCH.md) | Enable semantic memory search with embedrock + Cohere Embed v4 |
| [BOOTSTRAP-OUTLINE-NOTES.md](BOOTSTRAP-OUTLINE-NOTES.md) | Self-hosted Outline wiki setup + workspace sync cron |
| [BOOTSTRAP-PIPELINE-NOTIFICATIONS.md](BOOTSTRAP-PIPELINE-NOTIFICATIONS.md) | CodePipeline + GitHub Actions → Telegram + OpenClaw alerts |
| [BOOTSTRAP-GITHUBACTION-CODE-REVIEW.md](BOOTSTRAP-GITHUBACTION-CODE-REVIEW.md) | Add Claude Code PR + commit review to GitHub repos |
| [BOOTSTRAP-TELEGRAM.md](BOOTSTRAP-TELEGRAM.md) | Set up Telegram bot + communication rules (formatting, buttons, reactions) |
| [OPTIMIZE-TOO-LARGE-CONTEXT.md](OPTIMIZE-TOO-LARGE-CONTEXT.md) | Reduce context window bloat — slim SOUL.md, extract skills |

## Recommended Run Order (New Instance)

1. **MODEL-CONFIG** — always first, saves tokens on everything that follows
2. **SECURITY** — always second
2. **SECRETS-MANAGEMENT** — install git-secrets, establish rules
3. **SKILLS** — unlocks capabilities
4. **MEMORY-SEARCH** — enables semantic recall
5. **OUTLINE-NOTES** — set up team wiki (when needed)
6. **PIPELINE-NOTIFICATIONS** — wire up build alerts
7. **TELEGRAM** — create bot, wire up OpenClaw, add formatting rules to SOUL.md
8. **GITHUBACTION-CODE-REVIEW** — add to each repo as needed

> **Built-in (no bootstrap needed):** Heartbeat monitoring (`HEARTBEAT.md`), daily memory logging (`memory/YYYY-MM-DD.md`), long-term recall (`MEMORY.md`) — these are part of the OpenClaw runtime.

## Usage

These scripts are designed to be read by your Loki agent on first boot. They're included in the FastStart brain template and auto-loaded into the workspace.

You can also paste them into a conversation manually:

1. Copy the contents of the bootstrap file you want to run
2. Paste it as your first message to Loki
3. Loki will execute the steps and report back

Each bootstrap creates a marker file in `memory/` so it won't re-run on subsequent sessions.

## Adding New Bootstraps

Create a new `BOOTSTRAP-*.md` file following the same pattern:
- Clear numbered steps
- Marker file check at the top (`memory/.bootstrapped-*`)
- Marker file creation at the end
- No real secrets — use `YOUR_VALUE` placeholders throughout

## Related

- [loki-template-brain](https://github.com/inceptionstack/loki-template-brain) — Workspace template files (SOUL.md, AGENTS.md, etc.)
- [loki-skills](https://github.com/inceptionstack/loki-skills) — Skills library
- [embedrock](https://github.com/inceptionstack/embedrock) — Bedrock embedding proxy
