# Provider Packs Design — LLM Provider Decoupling

## Problem

Model IDs and provider config are hardcoded across 5+ files per pack. Changing a model name requires touching config-gen.py, install.sh, manifest.yaml, template.yaml, and bootstrap.sh. Worse, each agent pack (openclaw, hermes, pi, claude-code, etc.) independently handles provider selection, making it impossible to add new providers without modifying every pack.

## Goal

Decouple **LLM provider selection** from **agent pack selection**. User picks three things independently:
- **Agent pack**: openclaw, hermes, pi, claude-code, etc.
- **Permission profile**: builder, account_assistant, personal_assistant
- **LLM provider**: bedrock, anthropic-api, openai-api, litellm

## Architecture

### Directory Structure

```
providers/
  registry.yaml          # Provider catalog + compatibility matrix
  resolve.py             # Shared resolver: manifest + overrides → normalized config
  bedrock/
    manifest.yaml        # Model catalog, auth, defaults
  anthropic-api/
    manifest.yaml
  openai-api/
    manifest.yaml
  litellm/
    manifest.yaml
```

### Two-Layer Config Generation

**Layer 1: Provider Resolution** (shared, runs once)
`providers/resolve.py` reads the provider manifest, applies overrides, validates pack compatibility, and writes a normalized provider block into `/tmp/loki-pack-config.json`.

**Layer 2: Pack Rendering** (per-pack, each pack owns its own format)
Each pack's installer reads the resolved provider config and renders its own runtime config (openclaw.json, hermes config.yaml, pi models.json, claude-code env vars).

This keeps provider metadata DRY while respecting that each agent runtime has different config formats.

## Provider Manifest Schema

Each provider pack has a `manifest.yaml`:

```yaml
schemaVersion: v1
name: bedrock
displayName: AWS Bedrock
kind: llm-provider

auth:
  method: aws-sdk          # aws-sdk | api-key | proxy
  requiredEnv: []           # Env vars that MUST be set
  optionalEnv: [AWS_REGION] # Env vars that CAN be set
  secretSources: []         # Where secrets can come from

connection:
  transport: native         # native | openai-compatible
  api: bedrock-converse-stream
  baseUrlTemplate: "https://bedrock-runtime.{region}.amazonaws.com"
  regionRequired: true

defaults:
  primaryModel: global.anthropic.claude-opus-4-6-v1
  fallbackModel: global.anthropic.claude-sonnet-4-6
  heartbeatModel: global.anthropic.claude-sonnet-4-6

models:
  - id: global.anthropic.claude-opus-4-6-v1
    name: Claude Opus 4.6
    contextWindow: 200000
    maxTokens: 16384
    reasoning: true
    inputTypes: [text, image]
  - id: global.anthropic.claude-sonnet-4-6
    name: Claude Sonnet 4.6
    contextWindow: 200000
    maxTokens: 16384
    reasoning: true
    inputTypes: [text, image]

compatibility:
  packs: [openclaw, hermes, pi, ironclaw, nemoclaw, claude-code, kiro-cli]
```

**Design decision:** Provider manifests do NOT contain pack-specific rendering hints. Each pack owns how it translates provider metadata into its own config. This prevents providers from coupling to pack internals.

## Provider Examples

### Bedrock (default)
- Auth: IAM/instance profile (no keys needed)
- Models: `global.anthropic.claude-opus-4-6-v1` (primary), `global.anthropic.claude-sonnet-4-6` (fallback)
- Context: 200K on both
- Compatible with ALL packs

### Anthropic API
- Auth: `ANTHROPIC_API_KEY` (env or Secrets Manager)
- Models: `claude-opus-4-6-20250514` (primary), `claude-sonnet-4-6-20250514` (fallback)
- Context: 200K on both
- Phase 1: OpenClaw only

### OpenAI API
- Auth: `OPENAI_API_KEY` (env or Secrets Manager)
- Models: `gpt-4.1` (primary), `gpt-4.1-mini` (fallback)
- Context: 1M / 1M
- Phase 1: OpenClaw only

### LiteLLM
- Auth: optional `LITELLM_API_KEY` + required base URL
- Models: `claude-opus-4-6` / `claude-sonnet-4-6` (proxy-side IDs)
- Phase 1: OpenClaw only

## Provider Registry

`providers/registry.yaml` — lightweight catalog for validation:

```yaml
version: 1
default_provider: bedrock

providers:
  bedrock:
    description: "AWS Bedrock (IAM auth, no keys needed)"
    secret_required: false
    supported_packs: [openclaw, hermes, pi, ironclaw, nemoclaw, claude-code, kiro-cli]
  anthropic-api:
    description: "Direct Anthropic API"
    secret_required: true
    supported_packs: [openclaw]
  openai-api:
    description: "Direct OpenAI API"
    secret_required: true
    supported_packs: [openclaw]
  litellm:
    description: "LiteLLM proxy"
    secret_required: maybe
    supported_packs: [openclaw]
```

## Normalized Resolved Config

After `resolve.py` runs, `/tmp/loki-pack-config.json` gets a `provider` block:

```json
{
  "pack": "openclaw",
  "profile": "builder",
  "region": "us-east-1",
  "provider": {
    "name": "bedrock",
    "auth_method": "aws-sdk",
    "transport": "native",
    "api": "bedrock-converse-stream",
    "region": "us-east-1",
    "base_url": "https://bedrock-runtime.us-east-1.amazonaws.com",
    "model_roles": {
      "primary": "global.anthropic.claude-opus-4-6-v1",
      "fallback": "global.anthropic.claude-sonnet-4-6",
      "heartbeat": "global.anthropic.claude-sonnet-4-6"
    },
    "models": [...]
  },
  "model": "",
  "model_mode": "bedrock",
  "gw_port": "3001"
}
```

Legacy keys (`model`, `model_mode`, `litellm_url`, etc.) remain for backward compatibility during migration.

## Bootstrap CLI Contract

### New flags
```bash
bootstrap.sh --pack openclaw --provider bedrock --region us-east-1
bootstrap.sh --pack openclaw --provider anthropic-api --provider-key "$KEY"
bootstrap.sh --pack openclaw --provider openai-api --provider-key-secret-id /my/secret
```

### Backward compatibility
- `--model-mode bedrock` → implies `--provider bedrock`
- `--model-mode litellm` → implies `--provider litellm`  
- `--model-mode api-key` → implies `--provider anthropic-api`
- `--model` still works as primary model override regardless of provider
- Emit deprecation warning when `--model-mode` used without `--provider`

### Precedence
1. Explicit `--model` / `--provider-primary-model` override
2. Provider manifest defaults
3. Legacy fallback behavior

## CloudFormation Parameters

### Add
```yaml
ProviderName:
  Type: String
  Default: bedrock
  AllowedValues: [bedrock, anthropic-api, openai-api, litellm]
  Description: "LLM provider. Bedrock recommended (uses IAM, no keys needed)."

ProviderApiKeySecretArn:
  Type: String
  Default: ''
  Description: "Secrets Manager ARN for provider API key (anthropic-api/openai-api)."
```

### Keep (with updated descriptions)
- `DefaultModel` — "Override primary model. Leave empty to use provider default."
- `BedrockRegion` — still needed for Bedrock provider
- `ProviderApiKey` — direct key for testing (prefer SecretArn for production)

### Deprecate (keep for compatibility)
- `ModelMode` — replaced by `ProviderName`
- `LiteLLMBaseUrl`, `LiteLLMApiKey`, `LiteLLMModel` — folded into provider config

### CFN UX
- Replace "Model Access" parameter group with "LLM Provider"
- `ProviderName` dropdown gives users clear provider selection
- Bedrock default shows in the console (no empty fields)
- Add CFN Rules: require API key/secret when provider needs it

### StackSet consideration
Prefer `ProviderApiKeySecretArn` over `ProviderApiKey` for StackSets — secrets stay outside template history, support per-account/region replication.

## How Packs Consume Provider Config

### Extend `pack_config_get` for dotted paths:
```bash
# packs/common.sh
pack_config_get() {
  local key="$1" default="${2:-}"
  local config="${PACK_CONFIG:-/tmp/loki-pack-config.json}"
  if [[ -f "$config" ]] && command -v jq &>/dev/null; then
    local val
    val=$(jq -r "$(printf '%s' "$key" | awk -F. '{
      printf "."; for(i=1;i<=NF;i++) printf "[\"%s\"]",$i
    }') // empty" "$config" 2>/dev/null)
    [[ -n "$val" && "$val" != "null" ]] && { echo "$val"; return; }
  fi
  echo "$default"
}
```

### Pack installer pattern:
```bash
PROVIDER=$(pack_config_get provider.name "bedrock")
PRIMARY_MODEL=$(pack_config_get provider.model_roles.primary "")
FALLBACK_MODEL=$(pack_config_get provider.model_roles.fallback "")
```

### Per-pack rendering
- **OpenClaw**: `config-gen.py --config /tmp/loki-pack-config.json` reads provider block, renders openclaw.json
- **Hermes**: reads `provider.model_roles.primary`, converts to OpenAI-style ID for bedrockify
- **Pi**: reads provider models, writes `~/.pi/agent/models.json`
- **Claude Code**: reads provider, sets `CLAUDE_CODE_USE_BEDROCK=1` or `ANTHROPIC_API_KEY` accordingly

## Deployment Sequence

```
CFN Stack / StackSet
  → EC2 UserData (passes PackName, ProviderName, overrides, secret refs)
    → deploy/bootstrap.sh --pack openclaw --provider bedrock
      → providers/resolve.py (load manifest, merge overrides, validate)
        → /tmp/loki-pack-config.json (normalized provider config)
      → dependency packs (e.g. bedrockify)
        → reads provider.* from resolved config
      → target pack installer (e.g. openclaw/install.sh)
        → pack config generator (e.g. config-gen.py --config ...)
          → runtime config files (openclaw.json, etc.)
      → systemd service start
        → LLM provider (Bedrock / Anthropic / OpenAI / LiteLLM)
```

## Migration Plan

### Phase 1: Add provider infrastructure (no behavior change)
- Add `providers/` directory with registry + manifests + resolve.py
- Extend bootstrap.sh to accept `--provider`
- Write normalized provider block alongside legacy keys
- All packs continue reading legacy keys — nothing breaks

### Phase 2: Convert OpenClaw
- Rewrite config-gen.py to read from resolved provider config
- Remove model ID hardcoding from install.sh
- Keep `--model` as override, remove from defaults/help text

### Phase 3: Convert bedrockify-backed packs
- hermes, pi, ironclaw, nemoclaw read provider.model_roles
- bedrockify reads provider.models for default chat model
- Pack manifests stop carrying duplicate model IDs

### Phase 4: Update CFN
- Add ProviderName parameter + provider-aware overrides
- Keep DefaultModel/ModelMode as legacy
- Update parameter groups and labels

### Phase 5: Cleanup (later)
- Deprecate ModelMode
- Remove pack-specific model args (hermes-model, etc.)
- Trim legacy keys from resolved config

## Open Questions

1. Should `--model-mode api-key` default to `anthropic-api` or require explicit `--provider`?
2. Should bedrockify eventually support non-Bedrock upstreams, or stay Bedrock-only?
3. Which packs actually need non-Bedrock support beyond OpenClaw in phase 1?
4. Should costs be in manifests or omitted for non-Bedrock? (Recommend: optional, manually updated)
5. `gpt-4.1` vs `o3` as OpenAI default primary? (Recommend: `gpt-4.1` — broader availability)
6. Should resolved config persist to `~/.openclaw/state/` for debugging? (Recommend: yes, but strip secrets)

## Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Provider metadata location | `providers/<name>/manifest.yaml` | DRY, one file per provider |
| Pack rendering ownership | Each pack owns its own renderer | Prevents provider→pack coupling |
| Resolution language | Python | Already used, safer than shell YAML parsing |
| CFN default model field | Keep real value for Bedrock | Console UX matters for operators |
| Backward compatibility | Legacy flags map to new provider system | Existing StackSets must keep working |
| Secret handling | Env vars / Secrets Manager, never in config files | Security best practice for multi-account |
