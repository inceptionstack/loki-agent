# BOOTSTRAP-MODEL-CONFIG.md — Configure AI Models

> **Applies to:** All agents (with agent-specific sections below)

> **Run this FIRST — before all other bootstraps.**
> Sets the right models for each context so you get quality where it matters and cost savings everywhere else.
> If `memory/.bootstrapped-model-config` exists, skip.

## Model Strategy

- **Opus 4.6** — default for all interactive sessions (direct chat, sub-agents, coding tasks)
- **Sonnet 4.6** — for heartbeats and cron jobs (automated, background work that doesn't need heavy reasoning)

This gives you full Opus quality when talking to your human, while keeping automated/scheduled work cost-efficient.

## OpenClaw-Specific Configuration

### Step 1: Configure Explicit Model Entries + Default Model + Heartbeat

Register the models with explicit `contextWindow` and set the default model and heartbeat in a single patch:

```bash
openclaw config patch <<'EOF'
{
  "models": {
    "providers": {
      "amazon-bedrock": {
        "models": [
          {
            "id": "global.anthropic.claude-opus-4-6-v1",
            "name": "Claude Opus 4.6",
            "contextWindow": 200000,
            "maxTokens": 16384,
            "reasoning": true,
            "input": ["text", "image"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
          },
          {
            "id": "global.anthropic.claude-sonnet-4-6",
            "name": "Claude Sonnet 4.6",
            "contextWindow": 200000,
            "maxTokens": 16384,
            "reasoning": true,
            "input": ["text", "image"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "amazon-bedrock/global.anthropic.claude-opus-4-6-v1"
      },
      "heartbeat": {
        "model": "amazon-bedrock/global.anthropic.claude-sonnet-4-6"
      }
    }
  }
}
EOF
```

OpenClaw restarts automatically.

> **Why explicit model entries?** Bedrock auto-discovery uses a
> `defaultContextWindow` of 32K for discovered models. Without explicit entries
> that set `contextWindow: 200000`, Opus 4.6 gets capped at 32K — causing
> frequent "context limit exceeded" errors.

### Step 2: Configure Cron Jobs

All cron jobs with `payload.kind: "agentTurn"` should set their model to Sonnet 4.6.

When creating new cron jobs, always include the model field:

```json
{
  "payload": {
    "kind": "agentTurn",
    "message": "...",
    "model": "amazon-bedrock/global.anthropic.claude-sonnet-4-6"
  }
}
```

To update existing cron jobs that don't have a model set:

```bash
# List all cron jobs
openclaw cron list

# Update each job to use Sonnet
openclaw cron update <jobId> --model "amazon-bedrock/global.anthropic.claude-sonnet-4-6"
```

### Step 3: Verify

```bash
openclaw config get agents.defaults.model
```

Expected output:
```json
{
  "primary": "amazon-bedrock/global.anthropic.claude-opus-4-6-v1"
}
```

```bash
openclaw config get agents.defaults.heartbeat.model
```

Expected output:
```
amazon-bedrock/global.anthropic.claude-sonnet-4-6
```

```bash
openclaw config get models.providers.amazon-bedrock.models
```

Verify that both models show `"contextWindow": 200000` (not 32000).

## Why `global.` prefix?

The `global.` inference profile routes across all AWS regions automatically — no need to pick `us.` or `eu.`. Better availability, same price.

**Critical:** Use exact model IDs — Sonnet has no `-v1` suffix, Opus does:
- ✅ `global.anthropic.claude-sonnet-4-6` (no `-v1`)
- ✅ `global.anthropic.claude-opus-4-6-v1` (has `-v1`)

Mixing these up causes invocation errors.

## Hermes-Specific Configuration

Hermes uses bedrockify (OpenAI-compatible Bedrock proxy on `localhost:8090`) for model access. Model configuration is in `~/.hermes/config.yaml` and `~/.hermes/.env`.

### Step 1: Configure the Model

Edit `~/.hermes/config.yaml` and set the model ID (OpenAI-style, not Bedrock-style):

```yaml
model: "anthropic/claude-opus-4.6"
```

The model ID is translated by bedrockify to the corresponding Bedrock model.

### Step 2: Verify bedrockify Is Running

```bash
curl -sf http://127.0.0.1:8090/
# Expected: {"status":"ok","model":"..."}
```

### Step 3: Test the Model

```bash
curl -sf http://127.0.0.1:8090/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"anthropic/claude-opus-4.6","messages":[{"role":"user","content":"Say OK"}]}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])"
```

### Changing Models for Hermes

To switch Hermes to a different model (e.g., Sonnet for cost savings):

```yaml
# ~/.hermes/config.yaml
model: "anthropic/claude-sonnet-4.6"
```

Then restart Hermes. Bedrockify maps these OpenAI-style model IDs to Bedrock model IDs automatically.

## Pi-Specific Configuration

Pi uses bedrockify (OpenAI-compatible Bedrock proxy) for model access. Set the model in `~/.pi/agent/models.json` under the `bedrockify` provider entry:

```json
{
  "providers": {
    "bedrockify": {
      "models": [
        { "id": "anthropic/claude-opus-4.6" }
      ]
    }
  }
}
```

To switch to Sonnet for cost savings, change the `id` to `"anthropic/claude-sonnet-4.6"`. Pi has no cron or heartbeat system, so there's no separate heartbeat model to configure.

## IronClaw-Specific Configuration

IronClaw uses bedrockify via its OpenAI-compatible backend. Set the model in `~/.ironclaw/.env`:

```bash
LLM_BACKEND=openai_compatible
LLM_BASE_URL=http://127.0.0.1:8090/v1
LLM_API_KEY=not-needed
LLM_MODEL=anthropic/claude-opus-4.6
```

For scheduled routines (cron-equivalent), set a lighter model to save costs:

```bash
LLM_ROUTINE_MODEL=anthropic/claude-sonnet-4.6
```

Restart IronClaw after editing `.env`.

## Finish

```bash
mkdir -p memory && echo "Model config bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-model-config
```
