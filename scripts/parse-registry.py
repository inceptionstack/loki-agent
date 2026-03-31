#!/usr/bin/env python3
"""Parse packs/registry.yaml without PyYAML (stdlib only).

Usage:
  parse-registry.py <registry.yaml> list-agents
      Print pipe-delimited agent packs: name|description|experimental

  parse-registry.py <registry.yaml> get <pack> <key>
      Print a single value for a pack (e.g. instance_type, description)

The parser is a simple state machine that handles the flat two-level YAML
structure used by registry.yaml (top-level keys under 'packs:' at 2-space
indent, key-value pairs at 4-space indent).  It deliberately does NOT
handle arbitrary YAML — only the structure this project uses.
"""

import re
import sys


def parse_registry(text):
    """Return dict of {pack_name: {key: value, ...}} from registry YAML text."""
    current_pack = None
    packs = {}
    for line in text.split("\n"):
        # Top-level pack name (2-space indent under packs:)
        m = re.match(r"^  (\w[\w-]*):\s*$", line)
        if m:
            current_pack = m.group(1)
            packs[current_pack] = {}
            continue
        if current_pack:
            # Key-value pairs (4-space indent)
            kv = re.match(r"^    (\w[\w-]*):\s+(.+)$", line)
            if kv:
                val = kv.group(2).strip().strip('"').strip("'")
                packs[current_pack][kv.group(1)] = val
    return packs


def list_agents(packs):
    """Print pipe-delimited agent packs: name|description|experimental."""
    for name, cfg in packs.items():
        if cfg.get("type") == "agent":
            desc = cfg.get("description", name)
            exp = "true" if cfg.get("experimental", "").lower() == "true" else "false"
            print(f"{name}|{desc}|{exp}")


def get_value(packs, pack_name, key):
    """Print a single value for a pack, or empty string if missing."""
    cfg = packs.get(pack_name, {})
    print(cfg.get(key, ""))


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    registry_path = sys.argv[1]
    command = sys.argv[2]

    text = open(registry_path).read()
    packs = parse_registry(text)

    if command == "list-agents":
        list_agents(packs)
    elif command == "get" and len(sys.argv) >= 5:
        get_value(packs, sys.argv[3], sys.argv[4])
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
