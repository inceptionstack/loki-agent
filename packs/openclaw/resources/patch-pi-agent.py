#!/usr/bin/env python3
"""Patch pi-coding-agent for AWS SDK (instance profile) auth on Bedrock.

pi-coding-agent's auth pre-flight rejects AWS SDK auth when no API key is
present (EC2 instance roles use IMDS, not env vars / API keys). This script
patches two files in the installed dist:

  1. model-registry.js  — hasConfiguredAuth() returns true for amazon-bedrock
  2. agent-session.js   — _getRequiredRequestAuth() allows undefined apiKey

Usage: python3 patch-pi-agent.py <node_prefix>

These patches are overwritten on OpenClaw update. Upstream fix tracked at:
  OpenClaw auth-controller.ts should inject AWS SDK auth into pi's authStorage.
"""

import re
import sys
from pathlib import Path

MARKER = "/* LOKI-PATCH-BEDROCK-AUTH */"


def patch_model_registry(filepath: Path) -> bool:
    """Make hasConfiguredAuth() return true for amazon-bedrock provider."""
    if not filepath.exists():
        print(f"  [SKIP] {filepath} not found")
        return True

    text = filepath.read_text()
    if MARKER in text:
        print(f"  [OK] model-registry.js already patched")
        return True

    # Find hasConfiguredAuth() method and inject bedrock check before the return
    # Pattern: hasConfiguredAuth() { ... return <something>; }
    pattern = r'(hasConfiguredAuth\s*\(\)\s*\{)'
    replacement = (
        r'\1\n'
        f'        {MARKER}\n'
        '        if (this.providerId === "amazon-bedrock") return true;\n'
    )
    new_text, count = re.subn(pattern, replacement, text, count=1)
    if count == 0:
        print(f"  [WARN] Could not find hasConfiguredAuth() in model-registry.js")
        return False

    filepath.write_text(new_text)
    print(f"  [OK] Patched model-registry.js (hasConfiguredAuth)")
    return True


def patch_agent_session(filepath: Path) -> bool:
    """Allow undefined apiKey for amazon-bedrock in _getRequiredRequestAuth()."""
    if not filepath.exists():
        print(f"  [SKIP] {filepath} not found")
        return True

    text = filepath.read_text()
    if MARKER in text:
        print(f"  [OK] agent-session.js already patched")
        return True

    # Find _getRequiredRequestAuth and inject bedrock early-return
    # The method fetches auth and then throws if no apiKey — we intercept before the throw
    pattern = r'(_getRequiredRequestAuth\s*\([^)]*\)\s*\{)'
    replacement = (
        r'\1\n'
        f'        {MARKER}\n'
        '        const _bedrockProvider = this.providerId || this._providerId || "";\n'
        '        if (_bedrockProvider === "amazon-bedrock") {\n'
        '            const _bAuth = await this._getRequestAuth?.() || { ok: true, headers: {} };\n'
        '            return { apiKey: undefined, headers: _bAuth.headers || {} };\n'
        '        }\n'
    )
    new_text, count = re.subn(pattern, replacement, text, count=1)
    if count == 0:
        # Try alternate pattern — async method
        pattern2 = r'(async\s+_getRequiredRequestAuth\s*\([^)]*\)\s*\{)'
        replacement2 = (
            r'\1\n'
            f'        {MARKER}\n'
            '        const _bedrockProvider = this.providerId || this._providerId || "";\n'
            '        if (_bedrockProvider === "amazon-bedrock") {\n'
            '            const _bAuth = await this._getRequestAuth?.() || { ok: true, headers: {} };\n'
            '            return { apiKey: undefined, headers: _bAuth.headers || {} };\n'
            '        }\n'
        )
        new_text, count = re.subn(pattern2, replacement2, text, count=1)

    if count == 0:
        print(f"  [WARN] Could not find _getRequiredRequestAuth() in agent-session.js")
        return False

    filepath.write_text(new_text)
    print(f"  [OK] Patched agent-session.js (_getRequiredRequestAuth)")
    return True


def main():
    if len(sys.argv) < 2:
        print("Usage: patch-pi-agent.py <node_prefix>", file=sys.stderr)
        sys.exit(1)

    node_prefix = Path(sys.argv[1])
    pi_dist = node_prefix / "lib/node_modules/openclaw/node_modules/@mariozechner/pi-coding-agent/dist/core"

    if not pi_dist.exists():
        # Try alternate location (hoisted deps)
        pi_dist_alt = node_prefix / "lib/node_modules/@mariozechner/pi-coding-agent/dist/core"
        if pi_dist_alt.exists():
            pi_dist = pi_dist_alt
        else:
            print(f"  [WARN] pi-coding-agent dist not found at {pi_dist}")
            sys.exit(0)  # non-fatal

    ok1 = patch_model_registry(pi_dist / "model-registry.js")
    ok2 = patch_agent_session(pi_dist / "agent-session.js")

    if not (ok1 and ok2):
        sys.exit(1)


if __name__ == "__main__":
    main()
