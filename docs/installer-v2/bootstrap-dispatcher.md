# Bootstrap Dispatcher Specification

## Purpose

`install.sh` remains the stable public entrypoint for Loki installs, but its role is reduced to a small bootstrap dispatcher:

- normalize legacy flags into the shared `InstallRequest`
- detect whether V2 is safe and fast to launch
- fetch and verify the V2 binary when selected
- fall back to V1 conservatively when required

This document supersedes older `--experience` language. The public selector is `--engine v1|v2`.

---

## Dispatcher Scope

`install.sh` is responsible for:

- parsing a minimal stable CLI surface
- detecting OS, architecture, TTY, and AWS context signals
- deciding whether to run V1 or V2
- downloading the V2 binary with a hard 5-second timeout
- verifying SHA256 checksums and, when available or required, cosign signatures
- forwarding normalized arguments to the chosen engine

`install.sh` is not responsible for plan generation, deployment logic, metadata resolution, or interactive business logic.

---

## Routing Inputs

The dispatcher uses these inputs, in precedence order:

1. Explicit CLI engine selection: `--engine v1|v2`
2. Legacy alias: `--legacy` meaning `--engine v1`
3. Environment override: `LOKI_INSTALLER_ENGINE=v1|v2`
4. Emergency rollback toggle
5. Default rollout policy

### Emergency Rollback Toggle

The bootstrap must support a hard override to force V1 globally during rollout:

- `LOKI_INSTALLER_FORCE_V1=1`

Behavior:

- overrides rollout defaults
- ignores `LOKI_INSTALLER_ENGINE=v2`
- still allows explicit `--engine v2` only if `LOKI_INSTALLER_ALLOW_FORCED_V2=1` is also set

Recommended operational posture:

- default behavior in an incident: `LOKI_INSTALLER_FORCE_V1=1`
- break-glass opt-in for validation: `LOKI_INSTALLER_FORCE_V1=1 LOKI_INSTALLER_ALLOW_FORCED_V2=1`

---

## Environment Detection

The dispatcher performs only cheap, bootstrap-safe detection.

### OS Detection

Supported V2 bootstrap targets in the initial rollout:

- `linux`
- `darwin`

Unsupported OS:

- route to V1 immediately

Normalization:

- `uname -s` `Linux` -> `linux`
- `uname -s` `Darwin` -> `darwin`
- everything else -> unsupported

### Architecture Detection

Supported V2 bootstrap targets in the initial rollout:

- `amd64`
- `arm64`

Normalization:

- `x86_64` -> `amd64`
- `amd64` -> `amd64`
- `aarch64` -> `arm64`
- `arm64` -> `arm64`
- everything else -> unsupported

Unsupported architecture:

- route to V1 immediately

### TTY Detection

The dispatcher determines whether stdin and stdout are terminals:

- `interactive_candidate=true` only when `[ -t 0 ] && [ -t 1 ]`
- otherwise `interactive_candidate=false`

Rules:

- explicit non-interactive flags allow V2 in non-TTY contexts
- implicit interactive V2 must not launch a TUI without a TTY
- if the request appears interactive but no TTY is available, route to V1 unless the normalized request is sufficient for V2 headless mode

### AWS Detection

The dispatcher does not perform heavy AWS validation. It only captures routing hints:

- `aws_present=true` if `aws` is on `PATH`
- `aws_region_hint` from `AWS_REGION` or `AWS_DEFAULT_REGION`
- `aws_credentials_hint=true` if any of these are set:
  - `AWS_PROFILE`
  - `AWS_ACCESS_KEY_ID`
  - `AWS_WEB_IDENTITY_TOKEN_FILE`
  - `AWS_ROLE_ARN`

Rules:

- missing AWS hints do not block V2 download
- AWS validation remains V2/V1 engine work
- AWS hints may be logged for diagnostics and passed into normalized request context

---

## Normalized Request Model

The bootstrap must normalize user input into the shared contract fields from `installer-contract.md`:

- `engine`
- `mode`
- `pack`
- `profile`
- `method`
- `region`
- `stack_name`
- `auto_yes`
- `json_output`
- `resume_session_id`
- `extra_options`

### Mode Inference

- default mode is `interactive` when a TTY is available and the user did not provide enough headless arguments
- `-y`, `--yes`, or `--non-interactive` imply `auto_yes=true`
- `--non-interactive` forces `mode=non_interactive`
- non-TTY execution with sufficient arguments should normalize to `mode=non_interactive`

---

## Flag Mapping Table

The table below defines the bootstrap compatibility surface. "Old flag" means the stable user-facing flags handled by `install.sh`, including legacy aliases preserved for compatibility.

| Old flag / input | Accepted values | InstallRequest field | Normalization rule | Notes |
| --- | --- | --- | --- | --- |
| `--engine` | `v1`, `v2` | `engine` | exact enum match | Primary selector |
| `--legacy` | none | `engine` | set to `v1` | Legacy alias |
| `-y` | none | `auto_yes` | `true` | Also contributes to non-interactive inference |
| `--yes` | none | `auto_yes` | `true` | Same as `-y` |
| `--non-interactive` | none | `mode` and `auto_yes` | `mode=non_interactive`, `auto_yes=true` | Preserves old automation shape |
| `--pack` | string | `pack` | exact string | Required for deterministic headless install unless resume flow |
| `--profile` | string | `profile` | exact string | Optional at parse time |
| `--method` | `cfn`, `tf`, `terraform` | `method` | `tf -> terraform`; `terraform -> terraform`; `cfn -> cfn` | Canonical contract enum is `cfn` or `terraform` |
| `--region` | string | `region` | exact string | AWS region hint |
| `--stack-name` | string | `stack_name` | exact string | Required later if selected method requires it |
| `--json` | none | `json_output` | `true` | For machine-readable output |
| `--resume` | string | `resume_session_id` | exact string | Bootstrap routes to V2 only when supported |
| unknown `--key value` | string pair | `extra_options[key]` | preserve as normalized key/value only when explicitly allowlisted | Otherwise fail for V2, pass through to V1 when routed there |

### Unknown Flag Policy

For V2 routing:

- normalize only known flags and explicitly allowlisted extra options
- fail fast on unsupported flags before launch

For V1 routing:

- preserve legacy compatibility by forwarding unknown flags unchanged whenever safe

This keeps V2 strict without breaking existing V1 automation.

---

## Exact Routing Logic

The dispatcher must apply routing in this order.

### Step 1: Parse and normalize CLI intent

- parse `--engine`, `--legacy`, compatibility flags, and passthrough candidates
- construct a partial `InstallRequest`
- infer `mode`

### Step 2: Resolve requested engine

Resolved engine selection:

1. `--engine`
2. `--legacy`
3. `LOKI_INSTALLER_ENGINE`
4. rollout default

If `LOKI_INSTALLER_FORCE_V1=1`:

- resolved engine becomes `v1`
- unless both `--engine v2` and `LOKI_INSTALLER_ALLOW_FORCED_V2=1` are set

### Step 3: Apply hard V2 eligibility checks

V2 is ineligible if any of these are true:

- OS unsupported
- architecture unsupported
- explicit V1 selected
- forced rollback active without break-glass allowance
- interactive V2 requested but no TTY and insufficient headless inputs

If ineligible:

- route to V1 immediately

### Step 4: Apply V2 bootstrap acquisition checks

If V2 is requested or selected by default:

- download V2 release asset
- enforce 5-second timeout for the binary download
- fetch checksum file and optional cosign materials
- verify integrity and signature policy

If any acquisition or verification step fails:

- silently fall back to V1 by default
- if the user explicitly requested `--engine v2`, print a concise failure reason and exit non-zero instead of silently switching engines

### Step 5: Execute selected engine

- V1: invoke legacy installer path with original/compatible args
- V2: exec the downloaded `loki-installer` binary with normalized flags

---

## Fallback Decision Table

| Condition | Requested engine | Dispatcher action | User-visible behavior |
| --- | --- | --- | --- |
| `--engine v1` present | `v1` | run V1 | normal V1 |
| `--legacy` present | `v1` | run V1 | normal V1 |
| `LOKI_INSTALLER_FORCE_V1=1` | any/default | run V1 | normal V1 |
| OS unsupported for V2 | `v2` by default | run V1 | silent fallback |
| Arch unsupported for V2 | `v2` by default | run V1 | silent fallback |
| No TTY and request not resolvable headlessly | `v2` by default | run V1 | silent fallback |
| V2 binary download exceeds 5 seconds | `v2` by default | run V1 | silent fallback |
| V2 binary download exceeds 5 seconds | explicit `--engine v2` | fail | concise error, no silent engine switch |
| Checksum fetch fails | `v2` by default | run V1 | silent fallback |
| SHA256 mismatch | `v2` by default | run V1 | silent fallback plus local diagnostic log |
| SHA256 mismatch | explicit `--engine v2` | fail | integrity error, non-zero exit |
| Cosign required and signature verification fails | any V2 request | fail or fallback per explicitness rule | never run unverified V2 |
| Cosign unavailable but optional | `v2` by default | continue if SHA256 passes | no extra prompt |
| Unknown flag unsupported by V2 | `v2` by default | run V1 if compatible | silent compatibility fallback |
| Unknown flag unsupported by V2 | explicit `--engine v2` | fail | unsupported flag error |
| V2 launches successfully | `v2` | exec V2 | normal V2 |

### Silent Fallback Rule

Silent fallback is only allowed when the user did not explicitly pin `--engine v2`.

Reason:

- default-rollout users should get the most reliable install path
- operators who explicitly asked for V2 need deterministic failure instead of an unnoticed engine switch

---

## V2 Binary Download and Verification

### Release Source

V2 is distributed as GitHub Release assets.

Required release artifacts per version:

- `loki-installer-<os>-<arch>.tar.gz`
- `loki-installer-<os>-<arch>.tar.gz.sha256`

Optional release artifacts:

- `loki-installer-<os>-<arch>.tar.gz.sigstore.json`
- `loki-installer-<os>-<arch>.tar.gz.pem`
- `loki-installer-<os>-<arch>.tar.gz.sig`

The exact cosign artifact shape may vary, but the bootstrap contract is:

- always require SHA256 verification
- support cosign verification when cosign metadata is published
- allow enterprise policy to require cosign

### Timeout Requirement

Review note 3 requires a hard bootstrap SLA:

- if the V2 binary download does not complete within 5 seconds, stop attempting V2 and fall back to V1

Implementation rules:

- the 5-second limit applies to the binary asset request
- checksum and signature fetches should use the same short timeout budget class, but the mandatory rule is on the binary download itself
- partial downloads must be discarded

### SHA256 Verification

Verification flow:

1. download the binary archive to a temp file
2. download the matching `.sha256` file
3. compute local SHA256 of the downloaded archive
4. compare computed digest to the expected digest from the checksum file
5. continue only on exact match

Failure rules:

- checksum fetch failure: default V2 requests fall back to V1
- checksum mismatch: never execute the binary

### Cosign Verification

Cosign support is policy-driven.

Environment toggle:

- `LOKI_INSTALLER_REQUIRE_COSIGN=1`

Rules:

- if cosign metadata is present and `cosign` verification is available, verify the archive before execution
- if `LOKI_INSTALLER_REQUIRE_COSIGN=1`, absence of cosign metadata or verification failure blocks V2
- if cosign is optional and verification cannot be performed, SHA256 success is still sufficient for default rollout

Verification target:

- verify the downloaded release archive, not just the extracted binary

Security invariant:

- the dispatcher must never execute a V2 binary that failed SHA256 verification
- when cosign is required, the dispatcher must never execute a V2 binary that failed or skipped cosign verification

---

## Engine Invocation Rules

### V1 Invocation

V1 receives:

- original legacy flags where possible
- any unknown flags preserved for compatibility
- environment hints needed by existing behavior

### V2 Invocation

V2 receives:

- `install` subcommand unless the bootstrap later expands to dispatch other subcommands
- normalized flags only

Canonical invocation shape:

```bash
loki-installer install \
  --pack <pack> \
  [--profile <profile>] \
  [--method <cfn|terraform>] \
  [--region <region>] \
  [--stack-name <name>] \
  [--non-interactive] \
  [-y|--yes] \
  [--json] \
  [--resume <session_id>]
```

---

## Dispatcher Pseudocode

```text
function main(argv):
    raw = parse_bootstrap_args(argv)
    env = read_environment()

    detected_os = normalize_os(uname_s())
    detected_arch = normalize_arch(uname_m())
    has_tty = stdin_is_tty() && stdout_is_tty()

    request = normalize_install_request(raw, env, has_tty)

    requested_engine = resolve_engine_precedence(
        cli_engine=raw.engine,
        legacy_flag=raw.legacy,
        env_engine=env.LOKI_INSTALLER_ENGINE,
        default_engine=rollout_default(detected_os, detected_arch, has_tty, request)
    )

    if env.LOKI_INSTALLER_FORCE_V1 == "1":
        if not (raw.engine == "v2" and env.LOKI_INSTALLER_ALLOW_FORCED_V2 == "1"):
            return exec_v1(raw.argv_passthrough)

    if requested_engine == "v1":
        return exec_v1(raw.argv_passthrough)

    if detected_os not in {"linux", "darwin"}:
        return fallback_or_fail(raw, "unsupported_os")

    if detected_arch not in {"amd64", "arm64"}:
        return fallback_or_fail(raw, "unsupported_arch")

    if request.mode == "interactive" and not has_tty and not request_is_headless_complete(request):
        return fallback_or_fail(raw, "no_tty_for_interactive_v2")

    release = resolve_release_coordinates(version=desired_v2_version(), os=detected_os, arch=detected_arch)

    binary_archive = timed_download(release.binary_url, timeout_seconds=5)
    if binary_archive.failed:
        return fallback_or_fail(raw, "binary_download_timeout_or_failure")

    checksum_file = download(release.sha256_url)
    if checksum_file.failed:
        return fallback_or_fail(raw, "checksum_fetch_failed")

    if sha256(binary_archive.path) != parse_checksum(checksum_file.contents):
        return fallback_or_fail(raw, "checksum_mismatch")

    cosign_required = (env.LOKI_INSTALLER_REQUIRE_COSIGN == "1")
    cosign_materials = try_download_cosign_materials(release)

    if cosign_required or cosign_materials.present:
        cosign_result = verify_cosign(binary_archive.path, cosign_materials)
        if cosign_result.failed:
            return fallback_or_fail(raw, "cosign_verification_failed")

    extracted_binary = extract_archive(binary_archive.path)
    mark_executable(extracted_binary)

    v2_args = build_v2_args_from_request(request)
    return exec_v2(extracted_binary, v2_args)


function fallback_or_fail(raw, reason):
    log_bootstrap_reason(reason)

    if raw.engine == "v2":
        print_error(reason)
        exit(1)

    return exec_v1(raw.argv_passthrough)
```

---

## Logging and Diagnostics

Bootstrap logging should stay minimal to preserve the current install UX.

Rules:

- silent fallback for default-rollout users
- concise stderr error for explicit `--engine v2` failures
- optional local diagnostic log for support, including:
  - detected OS and arch
  - TTY state
  - timeout/fetch reason
  - checksum/cosign result
  - chosen engine

Recommended temp log location:

- `${TMPDIR:-/tmp}/loki-installer-bootstrap.log`

---

## Default Rollout Policy

Until V2 is the proven default, the dispatcher default should be conservative:

- default to V2 only on validated `linux|darwin` + `amd64|arm64` targets
- otherwise default to V1
- any bootstrap uncertainty before V2 execution resolves to V1 unless the user explicitly pinned `--engine v2`

This keeps the public `curl -sfL loki.run | bash` flow stable while allowing controlled V2 rollout.
