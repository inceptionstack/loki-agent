# Loki Installer V2 — Final Code Review

**Reviewer:** Loki@FastStart (automated)
**Branch:** `v2-cli`
**Date:** 2026-04-05

---

## 1. CORRECTNESS ⚠️ Needs Work

### CFN Adapter
- **Parameter mapping is mostly correct.** `PackName`, `ProfileName`, `EnvironmentName`, `DefaultModel`, `OpenClawGatewayPort` are all mapped to CFN parameters via `build_apply_stack_command()`.
- **Missing parameter mappings:** Pack-specific extra options like `bedrockify_port`, `embed_model`, `sandbox_name`, `telegram_token`, `allowed_chat_ids`, `hermes_model`, `haiku_model` are defined in pack manifests but **never mapped to CFN parameters**. They're resolved into `adapter_options` but `CloudFormationContext::from_plan()` only checks for `model` and `port`. These options would be silently ignored during CFN deployment.
- **`EnvironmentName` duplication:** The `parameter_overrides` always includes `("EnvironmentName", stack_name)` from `from_plan()`, and then the same pair appears in `build_apply_stack_command()` output via `parameter_overrides`. This means the CFN command will have `ParameterKey=EnvironmentName,ParameterValue=loki-openclaw` appearing **twice** — once from the hardcoded push in `from_plan()` and once from the loop. AWS CLI accepts duplicates (last wins), but it's confusing and fragile.

### Terraform Adapter
- **Variable mapping is reasonable.** `aws_region`, `pack_name`, `profile_name`, `environment_name`, `default_model`, `openclaw_gateway_port` are passed as `-var` flags.
- **Same pack-specific option gap** as CFN — pack options beyond `model` and `port` are silently dropped.

### Manifest ↔ CFN Template Alignment
- **`bedrockify` pack has a manifest** but is **NOT in the CFN template's `PackName` AllowedValues**. The CFN deploy would reject `bedrockify` as a pack. The manifest claims CFN is a supported method — this is incorrect for CFN.
- **`kiro-cli` IS in CFN AllowedValues** — ✅ aligned.
- **`nemoclaw` IS in CFN AllowedValues** — ✅ aligned.

### Dispatcher Routing
- The dispatcher correctly routes `--engine v1` to V1 and `--engine v2` to V2.
- The `canonical_method()` translates `tf` → `terraform` and passes `cfn` through — but the V2 binary expects clap `ValueEnum` values (`cfn` or `terraform`). ✅ Correct.

---

## 2. SECURITY ⚠️ Needs Work

### Command Injection
- **No shell injection risk.** All subprocess calls use `tokio::process::Command` with explicit program + args (not `sh -c`). User inputs are passed as separate arguments, not interpolated into shell strings. ✅ Good.
- **Dispatcher bash script:** All variables are properly quoted in `"$var"` form. `set -euo pipefail` is set. ✅ Good.

### SHA256 Verification
- The dispatcher's `download_and_verify_v2()` correctly:
  - Downloads archive and `.sha256` separately
  - Extracts expected hash with `awk '{print $1}'`
  - Compares with actual via `sha256_file()`
  - Returns non-zero on mismatch
  - Tests verify checksum mismatch triggers fallback or explicit failure
- **Issue:** The `sha256_file()` function uses `sha256sum` or `shasum -a 256` — both correct. But it checks `command -v` which could match aliases. Minor risk. ⚠️

### Sensitive Data
- No secrets are logged or persisted in session files directly.
- Pack options like `telegram_token` and `allowed_chat_ids` would be stored in the session JSON file on disk if the user passes them via `--option`. The session is written to `~/.local/state/loki-installer/sessions/` without restricted permissions. **Session files should be created with mode 0600.** ⚠️

---

## 3. ERROR HANDLING ✅ Good

- **Zero `.unwrap()` calls outside test code.** Every error path uses `?`, `map_err`, or explicit error types.
- `thiserror` is used consistently for `ManifestError`, `PlannerError`, `AdapterError`, `SessionError`.
- Error messages are actionable — they include remediation hints (e.g., "install awscli v2 and re-run").
- The CFN adapter handles rollback states, missing stacks, "no updates needed", credential errors, and region errors with specific messages.
- Session persistence uses atomic write (tmp → rename). ✅ Good.
- **Minor:** `color_eyre` is the top-level error handler but only used for CLI; core uses proper error types. Clean separation.

---

## 4. DRY / CODE QUALITY ⚠️ Needs Work

### Duplication
- `emit_step_started()` and `emit_step_finished()` are **duplicated verbatim** between `cfn.rs` and `terraform.rs`. These should be in `support.rs` or the adapter module root.
- `map_aws_command_failure()` in CFN handles credential/region/CLI-not-found errors; `ensure_terraform_success()` in Terraform does the same patterns. Could share a common error classifier.

### Function Length
- `apply_cloudformation()` is ~60 lines — acceptable.
- `build_apply_stack_command()` is cleanly factored.
- `Planner::build_plan()` is ~50 lines — acceptable.
- Overall function sizes are reasonable.

### Naming
- Consistent use of `snake_case` for fields, `CamelCase` for types.
- `NoopEventSink` is clear.
- `CommandSpec` / `CommandOutput` are clear.

### Unused Code
- `DeployAction` enum has `UpdateStack`, `DestroyStack` variants that are **never constructed** by either adapter. Dead code.
- `PrerequisiteKind::AwsCallerIdentityResolvable` is defined but never used.
- `InstallPhase::DiscoverAwsContext`, `ResolveMetadata`, `Finalize` are defined but never used by either adapter.

---

## 5. TEST COVERAGE ⚠️ Needs Work

### What's Tested
- CLI argument parsing (all 6 subcommands) ✅
- Contract validation (request, plan, roundtrip serialization) ✅
- Manifest loading and cross-validation (packs ↔ profiles ↔ methods) ✅
- Planner integration (plan generation, option resolution, unknown option rejection) ✅
- Session persistence (write, read, resume with fake AWS binary) ✅
- CFN command construction and output parsing (unit tests) ✅
- Terraform command construction and output parsing (unit tests) ✅
- Dispatcher routing (V1 fallback, V2 forwarding, checksum failure) ✅

### What's Missing
- **No test for pack-specific options actually reaching CFN/TF parameters.** The `model` and `port` mapping is implicitly tested but `bedrockify_port`, `embed_model`, etc. are not — and they'd silently fail.
- **No negative test for CFN rollback handling** (the code handles it but tests don't exercise it).
- **No test for `resume` when session has no plan** (should return `NotResumable`).
- **Fake AWS binary doesn't cover `create-stack`** — only `update-stack`. The session test always hits the update path because `describe-stacks` returns a stack. No test exercises the create-stack code path.
- **No test for Terraform adapter execution** (only command construction is unit-tested).
- **No TUI tests at all** — the TUI module is significant (~757 lines across 8 files) but completely untested.

---

## 6. DISPATCHER (install.sh) ⚠️ Needs Work

### Routing Logic
- Engine precedence: explicit CLI → env var → default. ✅
- `LOKI_INSTALLER_FORCE_V1` with break-glass `LOKI_INSTALLER_ALLOW_FORCED_V2`. ✅
- Unknown flags trigger V1 fallback (unless `--engine v2` was explicit, then hard fail). ✅
- TTY detection for interactive mode. ✅

### Flag Mapping
- `--pack`, `--profile`, `--method`, `--region`, `--stack-name`, `--resume`, `--non-interactive`, `--yes`, `--json` all correctly mapped to V2 binary args. ✅
- `--method tf` canonicalized to `terraform`. ✅

### Bash Bug: Exit Code Loss
- `if ! download_and_verify_v2 ...; then case "$?" in ...` — when `! cmd` is used in bash and the command fails, `$?` inside the `then` block is `0` (the result of the `!` negation succeeding). This means the `case` block would **never match** `1`, `2`, or `3` — it would always fall through to `*) fallback_or_fail "binary_extract_failed"`.

**This is a real bug.** The exit code from `download_and_verify_v2` is lost. Fix:
```bash
download_and_verify_v2 "$detected_os" "$detected_arch"
rc=$?
if [[ $rc -ne 0 ]]; then
  case "$rc" in ...
```

---

## 7. MANIFESTS ⚠️ Needs Work

### Pack Manifests
- All 8 packs have valid `manifest.yaml` files with `schema_version: 1`.
- `allowed_profiles` and `supported_methods` are set for each.

### Alignment Issues
- **`bedrockify` claims `supported_methods: [cfn, terraform]`** but the CFN template `PackName` AllowedValues do NOT include `bedrockify`. CFN deploy would fail.
- **`openclaw` manifest is missing `personal_assistant`** from `allowed_profiles`, matching `personal_assistant.yaml` not listing `openclaw` in `supported_packs`. ✅ Consistent.
- **`nemoclaw` manifest only allows `personal_assistant`** — matches `registry.yaml`'s `compatible_profiles`. ✅ Consistent.
- **`hermes` experimental flag mismatch:** `registry.yaml` says `experimental: true` but `packs/hermes/manifest.yaml` says `experimental: false`.

---

## 8. DESIGN COMPLIANCE ✅ Good

- `InstallRequest` matches the contract spec exactly.
- Session persistence is JSON-only. ✅
- Engine selector is `--engine v1|v2` with `--experience` as compatibility alias. ✅
- Pack manifests at `packs/<name>/manifest.yaml`. ✅
- `status` and `doctor` commands implemented. ✅
- Single crate with future workspace extraction plan. ✅
- SHA256 verification with 5-second timeout. ✅
- **Minor deviation:** Cosign signature verification not implemented. Acceptable per design ("optional").

---

## 9. PRODUCTION READINESS ⚠️ Needs Work

### What Would Break Today
1. **Dispatcher exit code bug** — all download/checksum failures report wrong reason.
2. **`bedrockify` pack via CFN** — rejected by CloudFormation.
3. **Pack-specific options silently ignored** — user config not applied.
4. **Session files world-readable** — potential secret exposure.
5. **Uninstall is stubbed** — both adapters log but don't actually delete.
6. **`resolve_repo_path` walks ancestors** — could find wrong template in nested dirs.

---

## Top 5 Must-Fix Issues

1. **Dispatcher exit code loss** — `install.sh:220-228`: `if ! download_and_verify_v2 ...; then case "$?"` always sees `$?=0`, so the specific error reason (checksum vs download vs extract) is never correctly dispatched.

2. **`bedrockify` manifest claims CFN support but CFN template rejects it** — `packs/bedrockify/manifest.yaml:8` says `cfn` is supported, but `deploy/cloudformation/template.yaml:120` AllowedValues doesn't include `bedrockify`.

3. **Pack-specific options silently dropped by adapters** — `tools/loki-installer/src/adapters/cfn.rs:250-255` (`CloudFormationContext::from_plan`): only `model` and `port` are extracted. All other pack options are resolved but never forwarded to CFN parameters or TF variables.

4. **Session files created without restricted permissions** — `tools/loki-installer/src/core/session.rs`: `fs::write()` uses default umask. Should set mode 0600 since sessions may contain sensitive option values.

5. **CFN `EnvironmentName` parameter duplicated** — `tools/loki-installer/src/adapters/cfn.rs:244-245` pushes `EnvironmentName` into `parameter_overrides`, which are then iterated alongside hardcoded `PackName`/`ProfileName`, resulting in duplicate `EnvironmentName` entries in the AWS CLI command.

---

## Top 5 Nice-to-Have Improvements

1. **Extract duplicated `emit_step_started`/`emit_step_finished`** into `adapters/support.rs` — both adapters have identical copies.

2. **Remove dead enum variants** — `DeployAction::UpdateStack`, `DeployAction::DestroyStack`, `PrerequisiteKind::AwsCallerIdentityResolvable`, unused `InstallPhase` variants.

3. **Add create-stack test path** — fake AWS binary only handles update; add a "stack does not exist" scenario.

4. **Fix `hermes` experimental flag inconsistency** — `registry.yaml` vs `manifest.yaml` disagree.

5. **Add generic pack-option → parameter mapping** instead of hardcoding `model`/`port` per adapter.

---

## Overall Merge Readiness: **Needs Fixes**

The architecture is clean, the contract system is well-designed, error handling is solid, and the test suite covers the important paths. However, the dispatcher exit code bug (#1) would cause incorrect fallback behavior in production, the bedrockify/CFN mismatch (#2) would cause deployment failures, and the silent option dropping (#3) means users' configurations wouldn't actually be applied. Fix these three and this is ready to merge.
