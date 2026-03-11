# loki-bootstrap

Recommended bootstrap scripts for new Loki/OpenClaw instances. Run these on first boot to get a secure, capable agent environment.

## Available Bootstraps

| Script | Purpose |
|--------|---------|
| [BOOTSTRAP-SECURITY.md](BOOTSTRAP-SECURITY.md) | Enable security monitoring, budgets, and operational hygiene |
| [BOOTSTRAP-SKILLS.md](BOOTSTRAP-SKILLS.md) | Install the FastStart skills library |
| [BOOTSTRAP-MEMORY-SEARCH.md](BOOTSTRAP-MEMORY-SEARCH.md) | Enable semantic memory search with embedrock + Cohere Embed v4 |
| [BOOTSTRAP-MEMORY-LOGGING.md](BOOTSTRAP-MEMORY-LOGGING.md) | Daily memory logging pattern and long-term recall with MEMORY.md |
| [BOOTSTRAP-HEARTBEAT.md](BOOTSTRAP-HEARTBEAT.md) | Autonomous monitoring loop — task board, pipelines, security |
| [BOOTSTRAP-OUTLINE-SYNC.md](BOOTSTRAP-OUTLINE-SYNC.md) | Sync workspace docs to Outline wiki via daily crons |
| [BOOTSTRAP-GITHUBACTION-CODE-REVIEW.md](BOOTSTRAP-GITHUBACTION-CODE-REVIEW.md) | Add Claude Code PR + commit review to GitHub repos |
| [BOOTSTRAP-PIPELINE-NOTIFICATIONS.md](BOOTSTRAP-PIPELINE-NOTIFICATIONS.md) | Wire CodePipeline + GitHub Actions → Telegram + OpenClaw alerts |
| [BOOTSTRAP-TELEGRAM-FORMATTING.md](BOOTSTRAP-TELEGRAM-FORMATTING.md) | Telegram formatting rules (no tables, no headers) |
| [OPTIMIZE-TOO-LARGE-CONTEXT.md](OPTIMIZE-TOO-LARGE-CONTEXT.md) | Reduce context window bloat — slim SOUL.md, extract skills |

## Recommended Run Order (New Instance)

1. **SECURITY** — always first
2. **SKILLS** — unlocks capabilities
3. **MEMORY-SEARCH** — enables semantic recall
4. **MEMORY-LOGGING** — establishes logging discipline
5. **HEARTBEAT** — starts autonomous monitoring
6. **OUTLINE-SYNC** — connects to team wiki
7. **TELEGRAM-FORMATTING** — add rules to SOUL.md
8. **GITHUBACTION-CODE-REVIEW** — add to each repo as needed

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
- Summary report to the operator

## Related

- [loki-template-brain](https://github.com/inceptionstack/loki-template-brain) — Workspace template files (SOUL.md, AGENTS.md, etc.)
- [loki-skills](https://github.com/inceptionstack/loki-skills) — Skills library
- [embedrock](https://github.com/inceptionstack/embedrock) — Bedrock embedding proxy
