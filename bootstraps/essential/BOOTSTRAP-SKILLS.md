# BOOTSTRAP-SKILLS.md — Skills Library Setup

> **Applies to:** All agents (with agent-specific sections below)

> **Run this once on first boot.** If `memory/.bootstrapped-skills` exists, skip — you've already done this.

## 1. Install Skills

Clone the FastStart skills library into your workspace:

```bash
cd ~/.openclaw/workspace
git clone https://github.com/inceptionstack/loki-skills.git skills
```

This gives you specialized skills for:

| Category | Skills |
|----------|--------|
| **AWS Core** | aws-mcp, aws-infrastructure-as-code, cloud-architect, aws-agentcore |
| **Observability** | aws-observability, cloudwatch-application-signals, datadog, dynatrace |
| **Migration** | aws-graviton-migration, arm-soc-migration |
| **AI/ML** | strands, claude-agent-sdk, spark-troubleshooting-agent |
| **Serverless** | aws-amplify, lambda-durable, aws-healthomics |
| **Infrastructure** | terraform, saas-builder, cfn-stacksets |
| **Payments** | stripe, checkout |
| **DevOps** | figma, postman, neon, outline, reposwarm |
| **Testing** | cross-agent-test |

OpenClaw auto-discovers skills from the `skills/` directory — they're available immediately after cloning.

## 2. Verify

List the installed skills to confirm they're loaded:

```bash
ls -1 ~/.openclaw/workspace/skills/
```

Review what you have and tell the operator what capabilities are now available.

## 3. Keeping Skills Updated

To update skills later:

```bash
cd ~/.openclaw/workspace/skills && git pull
```

Consider adding this to a weekly cron to stay current.

## Pi-Specific Configuration

Pi has a TypeScript extensions system. Load FastStart skills by placing them (or symlinks) in `~/.pi/agent/extensions/`. Extensions must export a standard Pi extension interface.

The FastStart skills library is written for OpenClaw/Hermes — they won't load directly as Pi extensions. However, the reference docs and prompts in each skill directory are still useful as context when crafting Pi tasks.

To install a skill as a Pi extension, copy or adapt the skill's logic into a TypeScript file under `~/.pi/agent/extensions/`:

```bash
# Example: symlink a compatible extension
ln -s ~/.openclaw/workspace/skills/my-skill/pi-extension.ts ~/.pi/agent/extensions/my-skill.ts
```

Check the FastStart skills library for any skills that ship a `pi-extension.ts` file.

## IronClaw-Specific Configuration

IronClaw extends capabilities via MCP servers rather than a native skills system. Point IronClaw at the MCP servers that back each FastStart skill — see `BOOTSTRAP-MCPORTER.md` for server configs.

The FastStart skills library's reference docs are still useful as context. For skill-equivalent functionality in IronClaw, configure the corresponding MCP server in `~/.ironclaw/.env` or IronClaw's MCP config section.

## 4. Finish

After completing all steps:
```bash
mkdir -p memory && echo "Skills bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-skills
```

Report the full list of installed skills to the operator.

---

## OpenClaw-Specific Configuration

OpenClaw auto-discovers skills from the `skills/` directory in the workspace. After cloning, skills are available immediately — no additional configuration needed.

## Hermes-Specific Configuration

Hermes has its own skills system at `~/.hermes/skills/` with auto-discovery, the `skill_manage` tool, and Skills Hub support. It also supports **external skill directories** — point it at the shared FastStart skills library:

```yaml
# In ~/.hermes/config.yaml
skills:
  external_dirs:
    - ~/.openclaw/workspace/skills
```

This makes all FastStart skills available alongside Hermes's built-in and agent-created skills. Local skills at `~/.hermes/skills/` take precedence if names conflict.

Skills appear as slash commands (e.g. `/aws-mcp`), in `skills_list()`, and in natural conversation. Hermes loads them progressively to minimize token usage.

To install additional skills from the Hermes Skills Hub:

```bash
hermes skills browse
hermes skills install <skill-name>
```
