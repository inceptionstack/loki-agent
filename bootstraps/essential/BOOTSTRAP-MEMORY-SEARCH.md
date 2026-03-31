# BOOTSTRAP-MEMORY-SEARCH.md — Enable Semantic Memory Search with Bedrock Embeddings

> **Applies to:** All agents (with agent-specific sections below)

> **Run this once to enable memory search.** If `memory/.bootstrapped-memory-search` exists, skip — you've already done this.

## Overview

Semantic memory search uses an OpenAI-compatible embeddings API. [bedrockify](https://github.com/inceptionstack/bedrockify) — already installed as a dependency of all agent packs — provides `/v1/embeddings` on localhost, translating OpenAI embedding calls into Amazon Bedrock embedding calls. No external API keys needed — uses the EC2 instance profile.

```
memory_search → http://127.0.0.1:8090/v1/embeddings → bedrockify → Bedrock Titan Embed v2 → vector results
```

## Prerequisites

- EC2 instance with IAM role that has `bedrock:InvokeModel` permission
- Bedrock model access enabled for `amazon.titan-embed-text-v2:0` in us-east-1
- **bedrockify already running** — installed and started by the bedrockify pack (dependency of both OpenClaw and Hermes)

## Step 1: Verify bedrockify Is Running

bedrockify is installed as a systemd service by the bedrockify pack. No separate installation needed.

```bash
# Check service status
systemctl status bedrockify
# Should show: active (running)

# Health check
curl -s http://127.0.0.1:8090/
# Expected: {"status":"ok",...}
```

If bedrockify is not running, check the service:

```bash
sudo journalctl -u bedrockify -n 20
sudo systemctl restart bedrockify
```

## Step 2: Verify Embeddings Endpoint

**Single embedding:**
```bash
curl -s -X POST http://127.0.0.1:8090/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": "test embedding", "model": "amazon.titan-embed-text-v2:0"}' \
  | jq '{object, model, dims: (.data[0].embedding | length)}'
# Expected: {"object":"list","model":"amazon.titan-embed-text-v2:0","dims":1024}
```

**Batch embeddings:**
```bash
curl -s -X POST http://127.0.0.1:8090/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": ["first text", "second text"], "model": "amazon.titan-embed-text-v2:0"}' \
  | jq '{results: (.data | length), dims: [.data[].embedding | length]}'
# Expected: {"results":2,"dims":[1024,1024]}
```

## OpenClaw-Specific Configuration

### Step 3: Configure OpenClaw Memory Search

Add this to your `openclaw.json` under `agents.defaults`:

```json
"memorySearch": {
  "enabled": true,
  "provider": "openai",
  "remote": {
    "baseUrl": "http://127.0.0.1:8090/v1/",
    "apiKey": "not-needed"
  },
  "fallback": "none",
  "model": "amazon.titan-embed-text-v2:0",
  "query": {
    "hybrid": {
      "enabled": true,
      "vectorWeight": 0.7,
      "textWeight": 0.3
    }
  },
  "cache": {
    "enabled": true,
    "maxEntries": 50000
  }
}
```

Then restart the OpenClaw gateway.

### Step 4: Verify End-to-End

Ask the agent to run `memory_search` with any query. It should return ranked results from workspace memory files using hybrid search (70% vector, 30% text).

### Step 5: Backfill Existing Memory

After enabling semantic search for the first time, existing memory files are **not** automatically indexed. Run:

```bash
openclaw memory index --force
```

This vectorizes all current memory files. Without this step, `memory_search` will only find content written *after* the setup — silently missing everything prior.

### Memory Quality Matters

Vector search ranks results by cosine similarity. **Low-signal, repetitive content tanks the scores of everything nearby** — making recall unreliable even for genuinely useful memories.

#### What hurts search quality

High-frequency repetitive content compresses into a dense cluster in vector space. This raises the effective similarity floor and pushes useful content below the retrieval threshold.

The biggest offender is **heartbeat logs**:

```markdown
## Heartbeat 02:19 UTC
### Apps: ✅ frontend + api healthy
### Security Hub: no change — 1 CRITICAL, 94 HIGH
## Heartbeat 02:49 UTC
### Apps: ✅ frontend + api healthy
### Security Hub: no change — 1 CRITICAL, 94 HIGH
```

A single daily memory file can contain 40–50 of these. They're semantically near-identical, contribute nothing to recall, and dilute chunk quality across the entire index.

#### Rule: only write what changed

**Don't write:**
- "no change", "all healthy", "nothing to report"
- Repeated status confirmations
- Routine cron completions with no notable outcome

**Do write:**
- App went down or returned unexpected status
- Security finding count changed (new CVE, severity shift)
- A decision was made
- A bug was found or fixed
- A TODO was started or completed autonomously

#### Keep heartbeat files out of the index

If your agent writes verbose heartbeat logs that are useful for audit but not for recall, route them to a separate file pattern and exclude from indexing:

```bash
# Write heartbeat noise here (not indexed)
memory/heartbeat-YYYY-MM-DD.md

# Keep daily notes clean (indexed)
memory/YYYY-MM-DD.md
```

To exclude a pattern from indexing, configure the memory sources in `openclaw.json`:

```json
"memorySearch": {
  "sources": {
    "exclude": ["memory/heartbeat-*.md"]
  }
}
```

## Hermes-Specific Configuration

Hermes has its own built-in memory system:

- **MEMORY.md** (~2,200 chars) — agent's personal notes, environment facts, lessons learned
- **USER.md** (~1,375 chars) — user preferences, communication style
- **Session search** — FTS5 full-text search across all past sessions in `~/.hermes/state.db`

Hermes memory is managed via the `memory` tool (add/replace/remove) and injected into the system prompt at session start. Session search uses `session_search` for finding past conversations.

**Bedrockify embeddings** are still available on `localhost:8090` for custom embedding workflows or MCP-based memory extensions:

```bash
curl -s -X POST http://127.0.0.1:8090/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": "your text here", "model": "amazon.titan-embed-text-v2:0"}'
```

To configure Hermes memory limits:

```yaml
# In ~/.hermes/config.yaml
memory:
  memory_enabled: true
  user_profile_enabled: true
  memory_char_limit: 2200
  user_char_limit: 1375
```

## Supported Models

bedrockify supports embedding models based on the `--embed-model` flag set at install time. The default is `amazon.titan-embed-text-v2:0`. Common options:

| Model | ID | Dims |
|-------|----|------|
| **Titan Embed Text V2** (default) | `amazon.titan-embed-text-v2:0` | 1024 |
| Titan Embed G1 Text | `amazon.titan-embed-g1-text-02` | 1536 |
| Cohere Embed English v3 | `cohere.embed-english-v3` | 1024 |
| Cohere Embed Multilingual v3 | `cohere.embed-multilingual-v3` | 1024 |

To change the embedding model, update the bedrockify service configuration:

```bash
# Edit the bedrockify systemd service to change --embed-model
sudo systemctl edit bedrockify
# Add override for ExecStart with your preferred --embed-model
sudo systemctl restart bedrockify
```

## Finish

```bash
mkdir -p memory && echo "Memory search bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-memory-search
```
