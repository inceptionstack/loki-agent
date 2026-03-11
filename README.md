# loki-bootstrap

Recommended bootstrap scripts for new Loki/OpenClaw instances. Run these on first boot to get a secure, capable agent environment.

## Available Bootstraps

| Script | Purpose |
|--------|---------|
| [BOOTSTRAP-SECURITY.md](BOOTSTRAP-SECURITY.md) | Enable security monitoring, budgets, and operational hygiene |
| [BOOTSTRAP-SKILLS.md](BOOTSTRAP-SKILLS.md) | Install the FastStart skills library |
| [BOOTSTRAP-MEMORY-SEARCH.md](BOOTSTRAP-MEMORY-SEARCH.md) | Enable semantic memory search with Bedrock Titan Embed v2 proxy |
| [OPTIMIZE-TOO-LARGE-CONTEXT.md](OPTIMIZE-TOO-LARGE-CONTEXT.md) | Reduce context window bloat — slim SOUL.md, extract skills, remove duplication |

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

- [faststart-brain](https://github.com/inceptionstack/loki-template-brain) — Workspace template files (SOUL.md, AGENTS.md, etc.)
- [loki-skills](https://github.com/inceptionstack/loki-skills) — Skills library
