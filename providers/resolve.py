#!/usr/bin/env python3
"""Resolve provider manifests into /tmp/loki-pack-config.json."""

from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from string import Template
from typing import Any

import yaml


CONFIG_PATH = Path("/tmp/loki-pack-config.json")


def load_yaml(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    if not isinstance(data, dict):
        raise SystemExit(f"Invalid YAML object in {path}")
    return data


def load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise SystemExit(f"Invalid JSON object in {path}")
    return data


def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    with tmp_path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp_path, path)


def render_base_url(template: str | None, values: dict[str, str]) -> str:
    if not template:
        return ""
    return Template(template).safe_substitute(values)


def detect_auth_mode(manifest: dict[str, Any], provider_key: str, provider_auth_type: str = "") -> str:
    auth = manifest.get("auth", {})
    modes = auth.get("modes") or []
    if provider_auth_type:
        return provider_auth_type
    if provider_key and "bearer" in modes:
        return "bearer"
    if auth.get("defaultMode"):
        return str(auth["defaultMode"])
    if modes:
        return str(modes[0])
    return str(auth.get("method", ""))


def validate_pack_support(packs_registry: dict[str, Any], pack_name: str, provider_name: str) -> None:
    packs = packs_registry.get("packs") or {}
    if pack_name not in packs:
        raise SystemExit(f"Pack '{pack_name}' not found in packs/registry.yaml")

    supported = packs[pack_name].get("supported_providers") or []
    if provider_name not in supported:
        supported_str = ", ".join(supported) if supported else "(none)"
        raise SystemExit(
            f"Provider '{provider_name}' is incompatible with pack '{pack_name}'. "
            f"Supported providers: {supported_str}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve Loki provider manifests")
    parser.add_argument("--provider", required=True, help="Provider name")
    parser.add_argument("--pack", required=True, help="Pack name")
    parser.add_argument("--region", default="", help="Region override")
    parser.add_argument("--model", default="", help="Primary model override")
    parser.add_argument("--provider-key", default="", help="Provider key override for auth-mode resolution")
    parser.add_argument("--provider-auth-type", default="", help="Provider auth type override")
    parser.add_argument("--config", default=str(CONFIG_PATH), help="Config output path")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    manifest_path = repo_root / "providers" / args.provider / "manifest.yaml"
    packs_registry_path = repo_root / "packs" / "registry.yaml"

    if not manifest_path.exists():
        raise SystemExit(f"Provider manifest not found: {manifest_path}")
    if not packs_registry_path.exists():
        raise SystemExit(f"Pack registry not found: {packs_registry_path}")

    manifest = load_yaml(manifest_path)
    packs_registry = load_yaml(packs_registry_path)
    validate_pack_support(packs_registry, args.pack, args.provider)

    config_path = Path(args.config)
    existing = load_json(config_path)

    connection = manifest.get("connection") or {}
    defaults = manifest.get("defaults") or {}
    auth = manifest.get("auth") or {}

    region = args.region or str(existing.get("region") or "")
    auth_mode = detect_auth_mode(manifest, args.provider_key, args.provider_auth_type)

    primary_model = args.model or str(defaults.get("primaryModel") or "")
    fallback_model = str(defaults.get("fallbackModel") or "")
    heartbeat_model = str(defaults.get("heartbeatModel") or fallback_model)

    base_url_values = {
        "region": region,
        "provider": args.provider,
    }
    base_url = render_base_url(connection.get("baseUrlTemplate"), base_url_values)

    # H2: Validate required API key for non-IAM providers
    auth_method = auth.get("method", "")
    if auth_mode in ("api-key", "bearer") and not args.provider_key:
        if auth_method == "api-key" or (auth_mode == "bearer"):
            print(f"ERROR: Provider '{args.provider}' with auth_mode '{auth_mode}' requires --provider-key", file=sys.stderr)
            sys.exit(1)

    provider_block = {
        "schemaVersion": str(manifest.get("schemaVersion") or "v1"),
        "resolvedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "name": str(manifest.get("name") or args.provider),
        "displayName": str(manifest.get("displayName") or args.provider),
        "kind": str(manifest.get("kind") or "llm-provider"),
        "auth_method": str(auth.get("method") or ""),
        "auth_mode": auth_mode,
        "transport": str(connection.get("transport") or ""),
        "api": str(connection.get("api") or ""),
        "region": region,
        "base_url": base_url,
        "model_roles": {
            "primary": primary_model,
            "fallback": fallback_model,
            "heartbeat": heartbeat_model,
        },
        "models": manifest.get("models") or [],
    }

    if not connection.get("regionRequired"):
        provider_block["region"] = ""

    existing["provider"] = provider_block
    if args.pack:
        existing["pack"] = args.pack
    if region:
        existing["region"] = region

    write_json_atomic(config_path, existing)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
