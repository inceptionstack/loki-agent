# BOOTSTRAP-MODEL-CONFIG.md — Configure AI Models

> **Run this FIRST — before all other bootstraps.**
> Sets the most cost-efficient models so every subsequent bootstrap step costs less.
> If `memory/.bootstrapped-model-config` exists, skip.

## Why First?

Every bootstrap step runs inference. Using the right model from the start saves tokens on all subsequent work:
- **Sonnet** handles most tasks well at lower cost
- **Opus** only kicks in as fallback for complex reasoning

## Step 1: Configure Models

Run this OpenClaw config patch:

```bash
openclaw config patch <<'EOF'
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "amazon-bedrock/global.anthropic.claude-sonnet-4-6",
        "fallbacks": ["amazon-bedrock/global.anthropic.claude-opus-4-6-v1"]
      }
    }
  }
}
EOF
```

OpenClaw restarts automatically.

## Step 2: Verify

```bash
openclaw config get agents.defaults.model
```

Expected output:
```json
{
  "primary": "amazon-bedrock/global.anthropic.claude-sonnet-4-6",
  "fallbacks": ["amazon-bedrock/global.anthropic.claude-opus-4-6-v1"]
}
```

## Why `global.` prefix?

The `global.` inference profile routes across all AWS regions automatically — no need to pick `us.` or `eu.`. Better availability, same price.

**Critical:** Use exact model IDs — Sonnet has no `-v1` suffix, Opus does:
- ✅ `global.anthropic.claude-sonnet-4-6` (no `-v1`)
- ✅ `global.anthropic.claude-opus-4-6-v1` (has `-v1`)

Mixing these up causes invocation errors.

## Finish

```bash
mkdir -p memory && echo "Model config bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-model-config
```
