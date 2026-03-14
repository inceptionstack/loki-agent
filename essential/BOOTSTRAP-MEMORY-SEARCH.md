# BOOTSTRAP-MEMORY-SEARCH.md — Enable Semantic Memory Search with Bedrock Embeddings

> **Run this once to enable memory search.** If `memory/.bootstrapped-memory-search` exists, skip — you've already done this.

## Overview

OpenClaw's `memory_search` uses an OpenAI-compatible embeddings API. We run [embedrock](https://github.com/inceptionstack/embedrock) — a tiny Go binary that translates OpenAI `/v1/embeddings` calls into Amazon Bedrock embedding calls. No external API keys needed — uses the EC2 instance profile.

```
OpenClaw memory_search → http://127.0.0.1:8089/v1/embeddings → embedrock → Bedrock Cohere Embed v4 → vector results
```

## Prerequisites

- EC2 instance with IAM role that has `bedrock:InvokeModel` permission
- Bedrock model access enabled for `cohere.embed-v4:0` in us-east-1
- No Node.js or extra dependencies required — embedrock is a single static binary

## Step 1: Install embedrock

```bash
# Linux arm64 (EC2 Graviton)
curl -fsSL https://github.com/inceptionstack/embedrock/releases/latest/download/embedrock-linux-arm64 \
  -o /tmp/embedrock && chmod +x /tmp/embedrock && sudo mv /tmp/embedrock /usr/local/bin/embedrock

# Linux amd64
curl -fsSL https://github.com/inceptionstack/embedrock/releases/latest/download/embedrock-linux-amd64 \
  -o /tmp/embedrock && chmod +x /tmp/embedrock && sudo mv /tmp/embedrock /usr/local/bin/embedrock

# Verify
embedrock --version
```

## Step 2: Create a systemd service

```bash
sudo tee /etc/systemd/system/embedrock.service > /dev/null << 'EOF'
[Unit]
Description=embedrock - Bedrock embedding proxy
After=network.target

[Service]
Type=simple
User=ec2-user
ExecStart=/usr/local/bin/embedrock --port 8089 --region us-east-1 --model cohere.embed-v4:0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable embedrock
sudo systemctl start embedrock
```

## Step 3: Configure OpenClaw

Add this to your `openclaw.json` under `agents.defaults`:

```json
"memorySearch": {
  "enabled": true,
  "provider": "openai",
  "remote": {
    "baseUrl": "http://127.0.0.1:8089/v1/",
    "apiKey": "not-needed"
  },
  "fallback": "none",
  "model": "cohere.embed-v4:0",
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

## Step 4: Verify

**Service running:**
```bash
systemctl status embedrock
# Should show: active (running)
```

**Health check:**
```bash
curl -s http://127.0.0.1:8089/
# Expected: {"status":"ok","model":"cohere.embed-v4:0"}
```

**Single embedding:**
```bash
curl -s -X POST http://127.0.0.1:8089/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": "test embedding", "model": "cohere.embed-v4:0"}' \
  | jq '{object, model, dims: (.data[0].embedding | length)}'
# Expected: {"object":"list","model":"cohere.embed-v4:0","dims":1536}
```

**Batch embeddings:**
```bash
curl -s -X POST http://127.0.0.1:8089/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": ["first text", "second text"], "model": "cohere.embed-v4:0"}' \
  | jq '{results: (.data | length), dims: [.data[].embedding | length]}'
# Expected: {"results":2,"dims":[1536,1536]}
```

**End-to-end memory search:**
Ask Loki to run `memory_search` with any query. It should return ranked results from workspace memory files using hybrid search (70% vector, 30% text).

## Supported Models

embedrock auto-detects model family by ID prefix:

| Model | ID | Dims |
|-------|----|------|
| **Cohere Embed v4** (recommended) | `cohere.embed-v4:0` | 1536 |
| Cohere Embed English v3 | `cohere.embed-english-v3` | 1024 |
| Cohere Embed Multilingual v3 | `cohere.embed-multilingual-v3` | 1024 |
| Titan Embed Text V2 | `amazon.titan-embed-text-v2:0` | 1024 |
| Titan Embed G1 Text | `amazon.titan-embed-g1-text-02` | 1536 |

## Finish

```bash
mkdir -p memory && echo "Memory search bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-memory-search
```
