# Embedrock — Bedrock Embeddings for Loki

## The Problem

OpenClaw's semantic memory search expects an OpenAI-compatible `/v1/embeddings` endpoint. Amazon Bedrock provides embedding models (Titan, Cohere) but uses a completely different API format. There's no built-in bridge.

Without embeddings, Loki can only do keyword-based memory search — which misses semantically related content ("what did we decide about IAM" won't find a note titled "access control policy changes").

## The Solution

[embedrock](https://github.com/inceptionstack/embedrock) is a lightweight Go proxy that translates OpenAI embedding API calls to Amazon Bedrock. It's a drop-in replacement — any tool expecting `/v1/embeddings` works without changes.

- **Zero API keys** — uses your AWS credentials (EC2 instance profile)
- **Zero config for Loki** — the bootstrap script installs it as a systemd daemon
- **Single binary** — no dependencies, no containers, no runtime
- **Auto-update** — `embedrock update` self-updates from GitHub releases

## How Loki Uses It

```
Loki Memory Search → OpenClaw → /v1/embeddings → embedrock → Bedrock (Cohere Embed v4) → vector
```

When Loki runs `memory_search`, OpenClaw sends the query text to embedrock on `localhost:8089`. Embedrock translates it to a Bedrock `InvokeModel` call using Cohere Embed v4, returns the vector, and OpenClaw uses it to find semantically similar memory entries.

## Supported Models

| Model | ID | Dimensions | Notes |
|-------|-----|-----------|-------|
| Cohere Embed v4 | `cohere.embed-v4:0` | 1536 | **Recommended** — best quality |
| Cohere Embed English v3 | `cohere.embed-english-v3` | 1024 | Good, English only |
| Cohere Embed Multilingual v3 | `cohere.embed-multilingual-v3` | 1024 | Multi-language support |
| Titan Embed Text V2 | `amazon.titan-embed-text-v2:0` | 1024 | Default, solid baseline |

## Installation

The `BOOTSTRAP-MEMORY-SEARCH.md` essential bootstrap handles installation automatically. If you need to install manually:

```bash
# Download (ARM64 — Graviton EC2)
curl -fsSL https://github.com/inceptionstack/embedrock/releases/latest/download/embedrock-linux-arm64 \
  -o /usr/local/bin/embedrock
chmod +x /usr/local/bin/embedrock

# Install as systemd daemon with Cohere Embed v4
sudo embedrock --model cohere.embed-v4:0 install-daemon

# Verify
curl http://127.0.0.1:8089/
# {"status":"ok","model":"cohere.embed-v4:0"}
```

## OpenClaw Configuration

In your OpenClaw config (`~/.openclaw/config.yaml`), the memory search provider points to embedrock:

```yaml
memory:
  embeddings:
    provider: openai
    baseUrl: http://127.0.0.1:8089
    model: cohere.embed-v4:0
```

No API key needed — embedrock uses the EC2 instance profile for Bedrock access.

## Cost

Bedrock embedding costs are minimal:
- **Cohere Embed v4:** ~$0.10 per million tokens
- A typical memory search (100-200 token query against 1000 memory entries) costs fractions of a cent
- Daily cost for active use: < $0.01

## Self-Update

```bash
embedrock update
```

Downloads the latest release, verifies the checksum, and replaces the binary atomically. Restarts the systemd service if running as root.

## Source

[github.com/inceptionstack/embedrock](https://github.com/inceptionstack/embedrock) — Apache 2.0 licensed
