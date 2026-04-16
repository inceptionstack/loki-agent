# Upgrading OpenClaw to Claude Opus 4.7 on Bedrock

## Step 1: Patch pi-ai to support Opus 4.7

This must be done **before** configuring openclaw.json. Without it, Opus 4.7 fails on every agent turn with "invalid beta flag".

### Why

Opus 4.7 natively supports adaptive thinking. However, pi-ai's Bedrock provider (`@mariozechner/pi-ai`) injects a legacy `anthropic_beta: ["interleaved-thinking-2025-05-14"]` header for any model it doesn't recognize as adaptive-thinking-capable. Opus 4.7 rejects this flag.

There is no config-level workaround. The `interleavedThinking` option is internal to pi-ai and not exposed in `openclaw.json`.

### Symptoms (if not patched)

Gateway logs show on every agent turn:

```
LLM request rejected: invalid beta flag
{"type":"error","error":{"type":"invalid_request_error","message":"invalid beta flag"}}
```

### Root cause

In pi-ai's Bedrock provider, `supportsAdaptiveThinking()` only matches 4.6 model IDs. For unmatched models, `buildAdditionalModelRequestFields()` injects the legacy beta flag into the Converse request body.

### How to patch

File location (adjust the node version path if different):

```
~/.local/share/mise/installs/node/25.6.1/lib/node_modules/openclaw/node_modules/@mariozechner/pi-ai/dist/providers/amazon-bedrock.js
```

Find the `supportsAdaptiveThinking` function and add 4.7 (and future) model matches:

```diff
 function supportsAdaptiveThinking(modelId) {
     return (modelId.includes("opus-4-6") ||
         modelId.includes("opus-4.6") ||
+        modelId.includes("opus-4-7") ||
+        modelId.includes("opus-4.7") ||
         modelId.includes("sonnet-4-6") ||
-        modelId.includes("sonnet-4.6"));
+        modelId.includes("sonnet-4.6") ||
+        modelId.includes("sonnet-4-7") ||
+        modelId.includes("sonnet-4.7"));
 }
```

### Re-applying after upgrade

This patch lives inside `node_modules` and is overwritten by `npm install -g openclaw@latest`.

After upgrading, check if the fix is still needed:

```bash
grep -n "supportsAdaptiveThinking" ~/.local/share/mise/installs/node/25.6.1/lib/node_modules/openclaw/node_modules/@mariozechner/pi-ai/dist/providers/amazon-bedrock.js
```

If the function still only matches 4.6 models, re-apply the patch.

---

## Step 2: Update openclaw.json

### 2a. Add the Opus 4.7 model entry

Add to `models.providers.amazon-bedrock.models`:

```json
{
  "id": "us.anthropic.claude-opus-4-7",
  "name": "Claude Opus 4.7",
  "reasoning": true,
  "input": ["text", "image"],
  "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
  "contextWindow": 1000000,
  "maxTokens": 16384,
  "api": "bedrock-converse-stream"
}
```

Use the `us.` cross-region inference ID. The base ID (`anthropic.claude-opus-4-7`) does not support on-demand invocation on Bedrock.

### 2b. Set Opus 4.7 as the primary model

Set `agents.defaults.model`:

```json
{
  "primary": "amazon-bedrock/us.anthropic.claude-opus-4-7",
  "fallbacks": [
    "amazon-bedrock/global.anthropic.claude-opus-4-6-v1",
    "amazon-bedrock/global.anthropic.claude-sonnet-4-6"
  ]
}
```

---

## Step 3: Restart the gateway

```bash
oc gateway stop && oc gateway start
```

Wait ~5-7 seconds for the gateway to become healthy.
