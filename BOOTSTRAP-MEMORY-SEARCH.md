# BOOTSTRAP-MEMORY-SEARCH.md — Enable Semantic Memory Search with Bedrock Embeddings

> **Run this once to enable memory search.** If `memory/.bootstrapped-memory-search` exists, skip — you've already done this.

## Overview

OpenClaw's `memory_search` uses an OpenAI-compatible embeddings API. Since we're on AWS, we run a tiny local proxy that translates OpenAI `/v1/embeddings` calls into Amazon Bedrock Titan Embed calls. No external API keys needed — uses the EC2 instance profile.

```
OpenClaw memory_search → http://127.0.0.1:8089/v1/embeddings → Bedrock Titan Embed v2 → vector results
```

## Prerequisites

- EC2 instance with IAM role that has `bedrock:InvokeModel` permission for `amazon.titan-embed-text-v2:0`
- Node.js installed (via mise or system)
- Bedrock model access enabled for Titan Embed Text v2 in your region (us-east-1)

## Step 1: Create the Proxy Script

Save as `/home/ec2-user/bedrock-embed-proxy.mjs`:

```javascript
import http from 'http';
import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";

const client = new BedrockRuntimeClient({ region: "us-east-1" });
const MODEL_ID = "amazon.titan-embed-text-v2:0";
const PORT = 8089;

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', model: MODEL_ID }));
    return;
  }
  if (req.method !== 'POST' || !req.url.endsWith('/embeddings')) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not found' }));
    return;
  }
  let body = '';
  for await (const chunk of req) body += chunk;
  try {
    const { input, model } = JSON.parse(body);
    const inputs = Array.isArray(input) ? input : [input];
    const embeddings = await Promise.all(inputs.map(async (text, index) => {
      const cmd = new InvokeModelCommand({
        modelId: MODEL_ID,
        contentType: 'application/json',
        accept: 'application/json',
        body: JSON.stringify({ inputText: typeof text === 'string' ? text : String(text) }),
      });
      const resp = await client.send(cmd);
      const result = JSON.parse(new TextDecoder().decode(resp.body));
      return { object: 'embedding', index, embedding: result.embedding };
    }));
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      object: 'list',
      data: embeddings,
      model: model || MODEL_ID,
      usage: { prompt_tokens: inputs.reduce((s, t) => s + (typeof t === 'string' ? t.length : 0), 0), total_tokens: 0 },
    }));
  } catch (err) {
    console.error('Error:', err.message);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { message: err.message, type: 'server_error' } }));
  }
});
server.listen(PORT, '127.0.0.1', () => console.log(`Bedrock Embed Proxy on http://127.0.0.1:${PORT}`));
```

## Step 2: Install the AWS SDK Dependency

```bash
cd /home/ec2-user && npm install @aws-sdk/client-bedrock-runtime
```

## Step 3: Create a systemd Service

```bash
sudo tee /etc/systemd/system/bedrock-embed-proxy.service > /dev/null << 'EOF'
[Unit]
Description=Bedrock Embedding Proxy (OpenAI-compatible)
After=network.target

[Service]
Type=simple
User=ec2-user
ExecStart=/home/ec2-user/.local/share/mise/shims/node /home/ec2-user/bedrock-embed-proxy.mjs
Restart=always
RestartSec=5
Environment=HOME=/home/ec2-user

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable bedrock-embed-proxy
sudo systemctl start bedrock-embed-proxy
```

## Step 4: Configure OpenClaw

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

## Step 5: How to Test

**Test 1 — Proxy is running:**
```bash
systemctl status bedrock-embed-proxy
# Should show: active (running)
```

**Test 2 — Health check:**
```bash
curl -s http://127.0.0.1:8089/ | jq
# Expected: {"status":"ok","model":"amazon.titan-embed-text-v2:0"}
```

**Test 3 — Single embedding:**
```bash
curl -s -X POST http://127.0.0.1:8089/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": "test embedding", "model": "amazon.titan-embed-text-v2:0"}' \
  | jq '{object, model, dims: (.data[0].embedding | length)}'
# Expected: {"object":"list","model":"amazon.titan-embed-text-v2:0","dims":1024}
```

**Test 4 — Batch embeddings:**
```bash
curl -s -X POST http://127.0.0.1:8089/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": ["first text", "second text", "third text"], "model": "amazon.titan-embed-text-v2:0"}' \
  | jq '{results: (.data | length), dims: [.data[].embedding | length]}'
# Expected: {"results":3,"dims":[1024,1024,1024]}
```

**Test 5 — End-to-end memory search (from OpenClaw):**
Ask Loki to run `memory_search` with any query. It should return ranked results from workspace memory files using hybrid search (70% vector, 30% text).

## Finish

```bash
mkdir -p memory && echo "Memory search bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-memory-search
```
