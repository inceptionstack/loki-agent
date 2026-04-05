# Review Notes on V2 Design

These are the accepted review points to incorporate into the follow-on documents:

1. **Manifest location**: Put pack manifests inside `packs/<name>/manifest.yaml`, not in a separate `installer/manifests/` directory. One source of truth per pack.

2. **Session persistence**: JSON only, no SQLite. The session state is small and flat. SQLite adds painful cross-compilation complexity for arm64 Rust builds.

3. **Download timeout**: If V2 binary download takes >5 seconds, fall back to V1 silently. Don't make the user wait.

4. **Signature verification**: Specify the mechanism now — GitHub Release asset + SHA256 checksum file + optional cosign signature. Enterprise customers need this.

5. **Flag naming**: Use `--engine v1|v2` instead of `--experience v1|v2`. More natural for operators.

6. **Add `status` command**: `loki-installer status` reads the session file and shows: what was deployed, when, which pack/profile, stack status, instance health. Enterprise support teams need this.
