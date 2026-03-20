#!/usr/bin/env python3
"""Generate OpenClaw config. Args: bedrock_region model gw_port gw_token model_mode litellm_url litellm_key litellm_model provider_key"""
import json, sys
bedrock_region = sys.argv[1]
model = sys.argv[2]
gw_port = sys.argv[3]
gw_token = sys.argv[4]
model_mode = sys.argv[5] if len(sys.argv) > 5 else "bedrock"
litellm_url = sys.argv[6] if len(sys.argv) > 6 else ""
litellm_key = sys.argv[7] if len(sys.argv) > 7 else ""
litellm_model = sys.argv[8] if len(sys.argv) > 8 else "claude-opus-4-6"
provider_key = sys.argv[9] if len(sys.argv) > 9 else ""
cfg = {
  "models": {"providers": {"amazon-bedrock": {"baseUrl": f"https://bedrock-runtime.{bedrock_region}.amazonaws.com", "auth": "aws-sdk", "api": "bedrock-converse-stream", "models": []}}, "bedrockDiscovery": {"enabled": True, "region": "us-east-1", "providerFilter": ["anthropic"]}},
  "agents": {"defaults": {"model": {"primary": f"amazon-bedrock/{model}", "fallbacks": ["amazon-bedrock/us.anthropic.claude-sonnet-4-6"]}, "workspace": "/home/ec2-user/.openclaw/workspace", "compaction": {"mode": "safeguard"}, "maxConcurrent": 4, "subagents": {"maxConcurrent": 8}}},
  "tools": {"web": {"search": {"enabled": False}, "fetch": {"enabled": True}}},
  "hooks": {"internal": {"enabled": True, "entries": {"boot-md": {"enabled": True}, "bootstrap-extra-files": {"enabled": True}, "command-logger": {"enabled": True}, "session-memory": {"enabled": True}}}},
  "gateway": {"port": int(gw_port), "mode": "local", "bind": "loopback", "auth": {"mode": "token", "token": gw_token}}
}
if model_mode == "litellm" and litellm_url and litellm_key:
  cfg["models"]["providers"]["litellm"] = {"baseUrl": litellm_url, "apiKey": litellm_key, "api": "openai-completions", "models": [
    {"id": "claude-opus-4-6", "name": "Claude Opus 4.6", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "claude-sonnet-4-6", "name": "Claude Sonnet 4.6", "reasoning": True, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 64000},
    {"id": "claude-3.5-haiku", "name": "Claude 3.5 Haiku", "reasoning": False, "input": ["text", "image"], "contextWindow": 200000, "maxTokens": 8192}]}
  cfg["agents"]["defaults"]["model"] = {"primary": f"litellm/{litellm_model}", "fallbacks": ["litellm/claude-sonnet-4-6", f"amazon-bedrock/{model}"]}
elif model_mode == "api-key" and provider_key:
  cfg["models"]["providers"]["anthropic"] = {"apiKey": provider_key, "models": []}
  cfg["agents"]["defaults"]["model"] = {"primary": "anthropic/claude-opus-4-6-20260514", "fallbacks": ["anthropic/claude-sonnet-4-6-20260514", f"amazon-bedrock/{model}"]}
with open("/home/ec2-user/.openclaw/openclaw.json", "w") as f:
  json.dump(cfg, f, indent=2)
print(f"Config written (mode={model_mode})")
