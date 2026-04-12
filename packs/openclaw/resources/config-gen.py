#!/usr/bin/env python3
"""Generate OpenClaw config from legacy args or a resolved config file."""

import json
import os
import sys


def usage() -> None:
    print(
        "Usage: config-gen.py --config /tmp/loki-pack-config.json\n"
        "   or: config-gen.py bedrock_region model gw_port gw_token "
        "[model_mode litellm_url litellm_key litellm_model provider_key]",
        file=sys.stderr,
    )


def normalize_provider_model(provider_alias: str, model_id: str) -> str:
    return f"{provider_alias}/{model_id}"


def build_base_config(gw_port: str, gw_token: str) -> dict:
    home = os.path.expanduser("~")
    return {
        "models": {"providers": {}},
        "plugins": {"entries": {}},
        "agents": {
            "defaults": {
                "model": {"primary": "", "fallbacks": []},
                "workspace": f"{home}/.openclaw/workspace",
                "compaction": {"mode": "safeguard"},
                "heartbeat": {
                    "model": "",
                    "target": "telegram",
                    "every": "30m",
                    "lightContext": True,
                    "isolatedSession": True,
                },
                "maxConcurrent": 4,
                "subagents": {"maxConcurrent": 8},
            }
        },
        "tools": {"web": {"search": {"enabled": False}, "fetch": {"enabled": True}}},
        "hooks": {
            "internal": {
                "enabled": True,
                "entries": {
                    "boot-md": {"enabled": True},
                    "bootstrap-extra-files": {"enabled": True},
                    "command-logger": {"enabled": True},
                    "session-memory": {"enabled": True},
                },
            }
        },
        "gateway": {
            "port": int(gw_port),
            "mode": "local",
            "bind": "loopback",
            "auth": {"mode": "token", "token": gw_token},
        },
    }


def legacy_defaults(provider_name: str, model_mode: str) -> tuple[str, str, str]:
    if provider_name == "litellm" or model_mode == "litellm":
        return ("claude-opus-4-6", "claude-sonnet-4-6", "claude-sonnet-4-6")
    if provider_name == "anthropic-api" or model_mode == "api-key":
        return (
            "claude-opus-4-6-20250514",
            "claude-sonnet-4-6-20250514",
            "claude-sonnet-4-6-20250514",
        )
    if provider_name == "openai-api":
        return ("gpt-4.1", "gpt-4.1-mini", "gpt-4.1-mini")
    if provider_name == "openrouter":
        return ("anthropic/claude-opus-4.1", "anthropic/claude-sonnet-4", "anthropic/claude-sonnet-4")
    return (
        "global.anthropic.claude-opus-4-6-v1",
        "global.anthropic.claude-sonnet-4-6",
        "global.anthropic.claude-sonnet-4-6",
    )


def load_runtime_input() -> dict:
    if len(sys.argv) >= 3 and sys.argv[1] == "--config":
        with open(sys.argv[2], "r", encoding="utf-8") as handle:
            return json.load(handle)

    if len(sys.argv) < 5:
        usage()
        sys.exit(1)

    return {
        "region": sys.argv[1],
        "model": sys.argv[2],
        "gw_port": sys.argv[3],
        "gw_token": os.environ.get("GW_TOKEN_ENV") or sys.argv[4],
        "model_mode": sys.argv[5] if len(sys.argv) > 5 else "bedrock",
        "litellm_url": sys.argv[6] if len(sys.argv) > 6 else "",
        "litellm_model": sys.argv[8] if len(sys.argv) > 8 else "claude-opus-4-6",
        "provider": None,
    }


data = load_runtime_input()
gw_token = os.environ.get("GW_TOKEN_ENV") or data.get("gw_token", "")
litellm_key = os.environ.get("LITELLM_KEY_ENV", "")
provider_key = os.environ.get("PROVIDER_KEY_ENV", "")
gw_port = data.get("gw_port", "3001")
provider = data.get("provider") or {}
provider_name = provider.get("name") or data.get("provider_name", "")
provider_models = provider.get("models") or []
provider_roles = provider.get("model_roles") or {}
region = provider.get("region") or data.get("region", "us-east-1")
model_mode = data.get("model_mode", "bedrock")

if not provider_name:
    if model_mode == "litellm":
        provider_name = "litellm"
    elif model_mode == "api-key":
        provider_name = "anthropic-api"
    else:
        provider_name = "bedrock"

default_primary, default_fallback, default_heartbeat = legacy_defaults(provider_name, model_mode)
primary_model = provider_roles.get("primary") or data.get("model") or default_primary
fallback_model = provider_roles.get("fallback") or default_fallback
heartbeat_model = provider_roles.get("heartbeat") or default_heartbeat

cfg = build_base_config(gw_port, gw_token)

if provider_name == "bedrock":
    bedrock = {
        "baseUrl": provider.get("base_url") or f"https://bedrock-runtime.{region}.amazonaws.com",
        "auth": "bearer" if provider.get("auth_mode") == "bearer" else "aws-sdk",
        "api": provider.get("api") or "bedrock-converse-stream",
        "models": provider_models,
    }
    if provider.get("auth_mode") == "bearer" and provider_key:
        bedrock["apiKey"] = "$env:PROVIDER_KEY_ENV"  # resolved at runtime, never written to disk
    cfg["models"]["providers"]["amazon-bedrock"] = bedrock
    cfg["plugins"]["entries"]["amazon-bedrock"] = {
        "config": {"discovery": {"enabled": True, "region": region, "providerFilter": ["anthropic"]}}
    }
    cfg["agents"]["defaults"]["model"] = {
        "primary": normalize_provider_model("amazon-bedrock", primary_model),
        "fallbacks": [normalize_provider_model("amazon-bedrock", fallback_model)],
    }
    cfg["agents"]["defaults"]["heartbeat"]["model"] = normalize_provider_model("amazon-bedrock", heartbeat_model)
elif provider_name == "litellm":
    base_url = provider.get("base_url") or data.get("litellm_url", "")
    model_id = primary_model or data.get("litellm_model") or "claude-opus-4-6"
    cfg["models"]["providers"]["litellm"] = {
        "baseUrl": base_url,
        "apiKey": "$env:LITELLM_KEY_ENV",  # resolved at runtime
        "api": provider.get("api") or "openai-completions",
        "models": provider_models,
    }
    cfg["agents"]["defaults"]["model"] = {
        "primary": normalize_provider_model("litellm", model_id),
        "fallbacks": [normalize_provider_model("litellm", fallback_model)],
    }
    cfg["agents"]["defaults"]["heartbeat"]["model"] = normalize_provider_model("litellm", heartbeat_model)
elif provider_name == "anthropic-api":
    cfg["models"]["providers"]["anthropic"] = {
        "apiKey": "$env:PROVIDER_KEY_ENV",  # resolved at runtime
        "models": provider_models,
    }
    cfg["agents"]["defaults"]["model"] = {
        "primary": normalize_provider_model("anthropic", primary_model),
        "fallbacks": [normalize_provider_model("anthropic", fallback_model)],
    }
    cfg["agents"]["defaults"]["heartbeat"]["model"] = normalize_provider_model("anthropic", heartbeat_model)
elif provider_name == "openai-api":
    cfg["models"]["providers"]["openai"] = {
        "apiKey": provider_key,
        "baseUrl": provider.get("base_url") or "https://api.openai.com/v1",
        "api": provider.get("api") or "responses",
        "models": provider_models,
    }
    cfg["agents"]["defaults"]["model"] = {
        "primary": normalize_provider_model("openai", primary_model),
        "fallbacks": [normalize_provider_model("openai", fallback_model)],
    }
    cfg["agents"]["defaults"]["heartbeat"]["model"] = normalize_provider_model("openai", heartbeat_model)
elif provider_name == "openrouter":
    cfg["models"]["providers"]["openrouter"] = {
        "apiKey": provider_key,
        "baseUrl": provider.get("base_url") or "https://openrouter.ai/api/v1",
        "api": provider.get("api") or "chat-completions",
        "models": provider_models,
    }
    cfg["agents"]["defaults"]["model"] = {
        "primary": normalize_provider_model("openrouter", primary_model),
        "fallbacks": [normalize_provider_model("openrouter", fallback_model)],
    }
    cfg["agents"]["defaults"]["heartbeat"]["model"] = normalize_provider_model("openrouter", heartbeat_model)
else:
    print(f"Unsupported provider '{provider_name}'", file=sys.stderr)
    sys.exit(1)

home = os.path.expanduser("~")
with open(f"{home}/.openclaw/openclaw.json", "w", encoding="utf-8") as handle:
    json.dump(cfg, handle, indent=2)
print(f"Config written (provider={provider_name})")
