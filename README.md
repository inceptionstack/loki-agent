# loki-bootstrap

Recommended bootstrap scripts for new Loki/OpenClaw instances. Run these on first boot to get a secure, capable agent environment.

## Core Bootstraps

| File | Purpose |
|------|---------|
| [BOOTSTRAP-MODEL-CONFIG.md](BOOTSTRAP-MODEL-CONFIG.md) | **Run first** — configure AI models (Sonnet default, Opus fallback) to save tokens on all other bootstraps |
| [BOOTSTRAP-SECURITY.md](BOOTSTRAP-SECURITY.md) | Enable Security Hub, Inspector, budgets, WAF, and operational hygiene |
| [BOOTSTRAP-SECRETS-AWS.md](BOOTSTRAP-SECRETS-AWS.md) | AWS Secrets Manager integration — exec provider, gotchas, troubleshooting |
| [BOOTSTRAP-SKILLS.md](BOOTSTRAP-SKILLS.md) | Install the FastStart skills library |
| [BOOTSTRAP-MEMORY-SEARCH.md](BOOTSTRAP-MEMORY-SEARCH.md) | Semantic memory search with embedrock + Cohere Embed v4 on Bedrock |
| [BOOTSTRAP-CODING-GUIDELINES.md](BOOTSTRAP-CODING-GUIDELINES.md) | Coding standards — testing, linting, commit conventions, CI/CD rules |
| [BOOTSTRAP-DISK-SPACE-STRAT.md](BOOTSTRAP-DISK-SPACE-STRAT.md) | EC2 disk space strategy — secondary EBS data volume, nightly cleanup cron, Docker/tmp offloading |
| [BOOTSTRAP-DAILY-UPDATE.md](BOOTSTRAP-DAILY-UPDATE.md) | Daily morning briefing cron — costs, security findings, pipeline health |
| [BOOTSTRAP-PIPELINE-NOTIFICATIONS.md](BOOTSTRAP-PIPELINE-NOTIFICATIONS.md) | CodePipeline + GitHub Actions → Telegram + OpenClaw webhook alerts |
| [BOOTSTRAP-WEB-UI.md](BOOTSTRAP-WEB-UI.md) | Expose OpenClaw Control UI via CloudFront + Cognito — ALB, proxy, WebSocket, device pairing |

## Optional Bootstraps (`optional/`)

| File | Purpose |
|------|---------|
| [BOOTSTRAP-TELEGRAM.md](optional/BOOTSTRAP-TELEGRAM.md) | Create Telegram bot, wire up OpenClaw, add formatting/reaction rules to SOUL.md |
| [BOOTSTRAP-OUTLINE-NOTES.md](optional/BOOTSTRAP-OUTLINE-NOTES.md) | Self-hosted Outline wiki (ECS + Aurora + S3 + Cognito OIDC) + workspace sync cron |
| [BOOTSTRAP-GITHUBACTION-CODE-REVIEW.md](optional/BOOTSTRAP-GITHUBACTION-CODE-REVIEW.md) | Add automatic Claude Code PR + commit review to GitHub repos via Actions |

## Optimization Guides

| File | Purpose |
|------|---------|
| [OPTIMIZE-TOO-LARGE-CONTEXT.md](OPTIMIZE-TOO-LARGE-CONTEXT.md) | Reduce context window usage — trim workspace files, manage memory, compaction strategies |

## Recommended Run Order (New Instance)

1. **MODEL-CONFIG** — always first, saves tokens on everything that follows
2. **SECURITY** — always second
3. **SECRETS-AWS** — git-secrets, Secrets Manager rules
4. **SKILLS** — unlocks capabilities
5. **MEMORY-SEARCH** — enables semantic recall
6. **TELEGRAM** — create bot, wire up OpenClaw, formatting rules
7. **CODING-GUIDELINES** — establish coding standards
8. **DISK-SPACE-STRAT** — set up data volume + nightly cleanup
9. **OUTLINE-NOTES** — team wiki (when needed)
10. **PIPELINE-NOTIFICATIONS** — wire up build alerts
11. **DAILY-UPDATE** — morning briefing cron
12. **GITHUBACTION-CODE-REVIEW** — add to each repo as needed
13. **WEB-UI** — expose Control UI via CloudFront (when ready for browser access)

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
