# Manual Testing Log — codex-cli pack (PR #8)

This file captures the **manual tests** run against the `add-codex-cli-pack` branch, in addition to the automated test suite. These were executed in three concentric rings: in-process merge block tests → host-level CLI tests → fresh-EC2 smoke test.

> Why document them? A few of these tests caught real bugs that the automated suite missed. Keeping the scenarios written down means the next pack change can re-run them and not regress.

---

## 1. In-process merge-block stress tests

**Purpose:** validate the Python `config.toml` merge logic (the risky part of the pack) against adversarial and edge-case inputs without spinning up any infra.

Ran against `packs/codex-cli/install.sh` HEAD. The Python block was extracted with `awk '/^PACK_MODEL=.*python3 - .*<<.PYEOF.$/,/^PYEOF$/'` and invoked directly on synthetic `config.toml` files.

| # | Scenario | Expected | Result |
|---|---|---|---|
| 1.1 | Empty `config.toml` | Managed block written at top | ✅ |
| 1.2 | User config with `[features]`, `[projects]`, `[plugins]`, `[mcp_servers]` tables | All user sections preserved, managed block prepended | ✅ |
| 1.3 | User has top-level `model = "gpt-4"` conflicting with our managed `model` | User's top-level `model` stripped, ours wins (no TOML duplicate-key error) | ✅ |
| 1.4 | `PACK_MODEL='evil"; rm -rf /'` (injection attempt) | Double-quote escaped to `\"` in output | ✅ `model = "evil\"; rm -rf /"` |
| 1.5 | `PACK_MODEL='gpt\turbo'` (backslash) | Backslash escaped to `\\` | ✅ `model = "gpt\\turbo"` |
| 1.6 | `PACK_MODEL=$'gpt\n5'` (newline in model) | Rejected with exit 2, clear stderr message | ✅ `error: model value contains newline:` |
| 1.7 | `PACK_MODEL=$'gpt\r5'` (carriage return) | Rejected with exit 2 | ✅ |
| 1.8 | `PACK_MODEL=''` (empty) | Writes empty-string model | ✅ `model = ""` |
| 1.9 | User has a stray START-sentinel comment but no real managed block | Stray preserved, managed block prepended | ✅ |
| 1.10 | Real managed block present AND stray START later in file | Only first (real) block stripped, stray preserved | ✅ |
| 1.11 | Re-run on existing managed block | Byte-identical output (idempotent) | ✅ |

**Verification command** (any commit):
```bash
bash tests/test-sync-registry.sh    # 35 assertions cover the registry side
bash packs/codex-cli/test.sh        # 28 contract assertions for this pack
```

---

## 2. Host-level CLI tests (isolated `HOME`)

**Purpose:** run the real `codex` binary against configs produced by our pack, without touching the developer's own `~/.codex`.

Setup: a throwaway `HOME=/tmp/codex-test-<n>/.codex` for every scenario so the developer's real codex auth is never at risk.

| # | Scenario | Result |
|---|---|---|
| 2.1 | Fresh install with empty `$HOME` → codex parses the output | ✅ `codex login status` → `Not logged in` (no parse error) |
| 2.2 | Re-run pack install on already-installed pack | ✅ SHA-256 of `config.toml` identical before and after |
| 2.3 | Pre-existing user `config.toml` with 4 tables merged | ✅ All 6 user sections preserved, 3 managed keys added, `codex` parses output |
| 2.4 | User has conflicting top-level `model`/`approval_policy`/`sandbox_mode` | ✅ Conflicts stripped, `web_search`/`personality`/`[features]` preserved, exactly 1 `model=` line |
| 2.5 | Arg parser — `--help`, `-h`, `--bogus`, positional arg, `--region` without value, `--model --region foo` | ✅ 8/8 correct exits (0 for help, 2 for errors), clean messages |
| 2.6 | Injection attempts on `--model` value (quote, backslash, newline, CR, empty) | ✅ Escape or reject; 7/7 correct |
| 2.7 | User tampered with managed block contents (e.g. added `something_rogue = "..."`) | ✅ Managed block reset cleanly, user content outside block preserved |
| 2.8 | Real `codex exec "..."` against our config | ✅ Codex loaded our config: `model: gpt-5.4, approval: never, sandbox: danger-full-access`; hit `wss://api.openai.com/v1/responses` and got 401 (expected — no auth) |
| 2.9 | Full `sync-registry` lifecycle — add pack to YAML, `--check` detects drift, regenerate, data round-trip | ✅ All 13 fields preserved (including nested ports object, arrays, bool) |

---

## 3. Fresh EC2 smoke test (production-like)

**Purpose:** run the pack install end-to-end on a brand-new EC2 instance matching the production target (AL2023 arm64, `t4g.medium`, stock AMI, user = `ec2-user`). This is the test that most closely mimics what a real customer sees after `curl -sfL install.lowkey.run | bash -s -- -y --pack codex-cli`.

### Procedure

1. Deploy minimal CloudFormation stack: one EC2 + IAM instance profile with SSM + Secrets Manager read; no VPC/app infrastructure beyond that.
2. Wait for SSM agent online.
3. Send a base64-encoded test script via `aws ssm send-command` (avoids JSON quoting hell).
4. The script:
   - Installs `git`
   - Installs `mise` + `node@latest` as `ec2-user` (production bootstrap parity)
   - Clones the lowkey branch
   - Runs `bash packs/codex-cli/install.sh --region us-east-1 --model gpt-5.4`
   - Verifies `codex --version`, `config.toml`, permissions, subcommand reachability
   - Checks the done-marker
   - Runs `packs/codex-cli/test.sh` on-instance
   - Re-runs install.sh to confirm idempotency (SHA-256 before/after)
   - Runs `scripts/sync-registry --check` and `tests/test-sync-registry.sh`
5. Delete the CloudFormation stack.

### Instance specs
- **AMI**: `al2023-ami-2023*-arm64` (latest at time of test, `ami-0f8245b8fac4d601a`)
- **Kernel**: `6.18.20-20.229.amzn2023.aarch64`
- **Instance type**: `t4g.medium`
- **User**: `ec2-user` via `sudo -u` (same path as `deploy/bootstrap.sh` uses)

### Bug found during this exercise

First smoke-test run **failed** with:

```
npm error code EACCES
npm error syscall mkdir
npm error path /usr/lib/node_modules/@openai
npm error errno -13
npm error Error: EACCES: permission denied, mkdir '/usr/lib/node_modules/@openai'
```

Root cause: when `mise`'s Node install step fails (e.g. missing `gpg` on a stripped-down AL2023), the shell falls back to the system `node`/`npm` from `dnf`, whose global prefix is `/usr/lib/node_modules` — root-owned. `npm install -g` as `ec2-user` is denied.

Production bootstrap hides this because it installs `gpg` + build tools first. But the pack must also work when run standalone, so:

**Fix (commit `209086c`): three-tier install strategy in `packs/codex-cli/install.sh`:**

1. If `mise` is present but npm prefix isn't writable, activate `mise` (forces user-owned prefix).
2. If npm prefix is user-writable, `npm install -g` directly.
3. Otherwise, fall back to `sudo --preserve-env=PATH npm install -g` with a clear warning pointing at `mise.run`.

If sudo is unavailable and we fall to step 3, the script fails fast with a helpful error instead of corrupting state.

### Post-fix smoke test — full log captured
```
✓ Activating mise to get a user-owned Node.js
⚠ npm prefix /usr is not user-writable — falling back to sudo
⚠ (install mise for rootless Node.js: curl -fsSL https://mise.run | sh)
added 2 packages in 4s
✓ Codex CLI installed: codex-cli 0.121.0
✓ Config merged: /home/ec2-user/.codex/config.toml
✓ Marker written: /tmp/pack-codex-cli-done
[PACK:codex-cli] INSTALLED — codex CLI ready (model: gpt-5.4)
```

### Checks verified on fresh EC2

| # | Check | Result |
|---|---|---|
| 3.1 | Pack install completes (exit 0) | ✅ |
| 3.2 | `codex --version` → `codex-cli 0.121.0` | ✅ |
| 3.3 | `/home/ec2-user/.codex/config.toml` contains our managed block | ✅ |
| 3.4 | File permissions `0600`, owner `ec2-user:ec2-user` | ✅ |
| 3.5 | `codex login status` exits 0 and prints `Not logged in` (= config parses, just not authed) | ✅ |
| 3.6 | `codex --help` lists all subcommands (exec, review, login, logout, mcp, mcp-server) | ✅ |
| 3.7 | `/tmp/pack-codex-cli-done` marker present | ✅ |
| 3.8 | `packs/codex-cli/test.sh` on-instance → 28/0 | ✅ |
| 3.9 | Re-run install → SHA-256 identical (idempotent on real EC2) | ✅ `f1d079f12ee2f9ee44…` |
| 3.10 | `scripts/sync-registry --check` | ✅ |
| 3.11 | `tests/test-sync-registry.sh` on-instance → 35/0 | ✅ |

---

## 4. Also discovered (informational, not blocking this PR)

- **`mise` needs `gpg` pre-installed** on AL2023 to verify Node.js tarballs. Standalone pack runs on minimal images may hit this. The real `deploy/bootstrap.sh` installs gpg + build tooling in Phase 1, so the production path is unaffected. Our three-tier npm strategy handles the fallback gracefully.
- **`codex exec <prompt>` on v0.118+**: The CLI now treats a trailing arg as prompt-supplementary stdin input rather than a standalone prompt. Not a pack bug — just noted for downstream skill authors who might automate `codex exec`.

---

## How to re-run these tests

**Merge block stress tests** — ~10 seconds, no infra:
```bash
# Extract the merge block, then feed it synthetic TOML
awk '/^PACK_MODEL=.*python3 - .*<<.PYEOF.$/,/^PYEOF$/' \
    packs/codex-cli/install.sh | sed '1d;$d' > /tmp/merge.py

# Then run your cases, e.g.
PACK_MODEL='evil"; rm -rf /' python3 /tmp/merge.py /tmp/t.toml
```

**Host-level CLI tests** — ~1 minute, no infra (but requires codex already installed somewhere):
```bash
# Use an isolated HOME so your own ~/.codex is never touched
RUN=/tmp/codex-iso && rm -rf "$RUN" && mkdir -p "$RUN/.codex"
HOME="$RUN" bash packs/codex-cli/install.sh --model gpt-5.4
HOME="$RUN" codex login status   # should print "Not logged in"
```

**Fresh EC2 smoke test** — ~5 minutes, costs a few cents. Scripts lived under `/tmp` during the original run; re-create them via:
1. Launch a `t4g.medium` AL2023-arm64 EC2 with an SSM-capable IAM role.
2. `aws ssm send-command` with an install script (`mise` setup → clone → `bash packs/codex-cli/install.sh` → verification). Base64-encode the script to sidestep JSON/shell quoting problems.
3. Delete the stack.

If you want a reusable harness, see the `/tmp/smoke-*.sh` scripts captured in the original session transcript, or port them to `tests/smoke-ec2.sh` as a follow-up.

---

## Commit history this log covers

| Commit | Change |
|---|---|
| `7648089` | codex-cli pack: builder agent, initial review fixes |
| `32f7e3c` | registry: YAML as single source of truth, JSON generated + sync-checked |
| `9dd0ade` | install.sh: arg validation, TOML escape, sentinel isolation |
| `507dfda` | ci: `tests/test-sync-registry.sh` (17 groups, 35 assertions) + dedicated CI workflow |
| `56e170b` | round-3 LOW findings: strict missing-value errors, README consistency |
| `209086c` | install.sh: handle root-owned npm prefix (found by this fresh-EC2 smoke test) |
