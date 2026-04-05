# Installer V2 Migration Plan

## Purpose

This document defines how Loki Agent Installer V2 rolls out from preview to standard default, how operators decide whether to advance between phases, when V1 remains the supported path, and how to force an emergency rollback to V1.

This plan treats the accepted review notes as binding:

- use `--engine v1|v2` as the primary selector; keep `--experience v1|v2` as a compatibility alias during migration
- store pack manifests in `packs/<name>/manifest.yaml`
- use JSON session persistence only
- silently fall back to V1 if V2 binary download takes more than 5 seconds
- verify V2 artifacts with GitHub Release asset + SHA256 checksum file, with optional cosign signature
- add `loki-installer status` before broad production rollout

## Invariants

The following rules apply in every phase:

- `curl -sfL loki.run | bash` remains the public entry point.
- `install.sh` is the dispatcher and compatibility layer; install business logic moves out of the bootstrap script.
- V1 remains the conservative fallback until Phase 4 exit criteria are met and the V1 deprecation conditions are satisfied.
- Old command shapes continue to route correctly even if the internal engine changes.
- V1 and V2 consume the same pack/profile/method metadata model.
- Fallback to V1 is allowed only before V2 mutates user infrastructure, or after an explicit operator decision that the target environment is safe to retry with V1.

## Engine Selection and Routing

Primary selectors during migration:

- `--engine v1`
- `--engine v2`
- `LOKI_INSTALLER_ENGINE=v1`
- `LOKI_INSTALLER_ENGINE=v2`

Compatibility aliases during migration:

- `--experience v1|v2`
- `LOKI_INSTALLER_EXPERIENCE=v1|v2`
- `--legacy` as alias for V1

Routing rules:

1. Explicit engine selection always wins.
2. Emergency rollback toggle forcing V1 overrides default routing, but not an explicit operator test of V2 in controlled environments.
3. Default routing follows the active rollout phase and validated-environment allowlist.
4. If V2 download exceeds 5 seconds, or download / checksum / signature verification fails, dispatch silently to V1 when safe.
5. If V2 starts execution and then fails, preserve JSON session state, print next-step guidance, and require an explicit retry, resume, or operator-approved fallback decision.

## Phase Plan

### Phase 0: V1 Only

Scope:

- Production installs run only through V1.
- V2 may exist in source control or CI, but it is not reachable from the public bootstrap path.

Entry criteria:

- Current stable state before dispatcher rollout.

Supported:

- V1 interactive and non-interactive installs.
- Existing bootstrap flags and workflows.

Best-effort:

- Internal V2 prototypes not exposed to end users.

Deprecated:

- Nothing.

Exit criteria:

- `install.sh` dispatcher exists but preserves V1 behavior by default.
- `--engine v1|v2` and compatibility aliases are parsed correctly.
- Shared metadata contract is defined.
- Artifact verification mechanism for V2 is implemented and testable.
- JSON session schema for V2 is defined.

Testing gate to Phase 1:

- Unit coverage for request parsing and routing.
- Compatibility tests showing old command shapes still resolve correctly.
- Integration tests proving default path is unchanged V1 behavior.

### Phase 1: Dispatcher Introduced, V2 Opt-In Preview

Scope:

- Dispatcher is live.
- Default remains V1.
- V2 is reachable only through explicit opt-in.

Entry criteria:

- Phase 0 exit criteria complete.

Supported:

- V1 for all production use.
- V2 only for preview users and internal validation through `--engine v2`.

Best-effort:

- V2 interactive preview.
- V2 non-interactive preview on validated operating systems and architectures only.

Deprecated:

- New operational guidance should stop recommending `--experience`; document `--engine` instead.

Exit criteria:

- V2 can complete `doctor` and preflight.
- V2 can resolve pack/profile/method metadata from the shared model.
- Silent fallback to V1 is implemented for download timeout, fetch failure, checksum failure, signature failure, unsupported platform, and known fallback environments.
- Preview documentation exists and clearly labels V2 as opt-in.
- `loki-installer status` can read the JSON session file for completed or failed V2 runs.

Testing gate to Phase 2:

- Integration tests for V2 binary fetch + verification.
- Integration tests for download timeout >5 seconds causing silent V1 fallback.
- Manual validation on macOS and Linux, in both TTY and non-TTY environments.
- Failure-path tests verifying JSON session persistence and `status` output.

### Phase 2: V2 Happy Paths Complete, Default Still V1

Scope:

- V2 supports the happy path for `doctor`, preflight, non-interactive install, and interactive install.
- Default remains V1.

Entry criteria:

- Phase 1 exit criteria complete.

Supported:

- V1 for general production use.
- V2 for explicit opt-in on validated environments.
- V2 `doctor`, preflight, interactive happy path, non-interactive happy path, and `status`.

Best-effort:

- Resume and retry outside the validated environment matrix.
- Unknown legacy flags routed to V2 only if they can be translated safely.

Deprecated:

- New docs and examples should no longer introduce V1-first workflows except as fallback guidance.

Exit criteria:

- Shared metadata is sourced from pack-local manifests at `packs/<name>/manifest.yaml`.
- V1 consumes shared metadata where practical so V1/V2 behavior matches.
- Non-interactive happy path success rate meets release target on the validated matrix.
- Resume logic works for supported failure points.
- Support team runbooks exist for choosing retry, resume, or fallback after V2 failure.

Testing gate to Phase 3:

- Full unit, integration, and compatibility suites green.
- Manual validation for failed deploy recovery and selected AWS auth scenarios.
- Side-by-side comparison confirming V1 and V2 resolve pack/profile/method combinations identically on supported inputs.
- Release artifact verification exercised against real release assets and checksum files.

### Phase 3: Default V2 on Validated Environments

Scope:

- Dispatcher defaults to V2 only on validated environments.
- V1 remains the default on unvalidated or known-risk environments.
- Automatic fallback to V1 remains enabled where safe.

Entry criteria:

- Phase 2 exit criteria complete.

Supported:

- V2 as default on validated platforms and scenarios.
- V1 as supported fallback and explicit selection everywhere else.
- `--engine v1` and `--engine v2`.

Best-effort:

- V2 on partially validated environments when explicitly selected by operators.
- Compatibility aliases for engine selection.

Deprecated:

- `--experience` and `LOKI_INSTALLER_EXPERIENCE`; keep them working but mark them for removal after V1 deprecation.
- Any pack/profile behavior implemented only in V1.

Exit criteria:

- Phase 3 defaults are stable for at least two release cycles.
- No open severity-1 or severity-2 rollout bugs blocking default V2 usage on validated environments.
- Support can diagnose live installs using `status`, session files, and dispatcher logs without needing bespoke engineering intervention for routine failures.
- Emergency rollback mechanism has been exercised in staging and production-like validation.

Testing gate to Phase 4:

- Canary metrics show V2 default installs meet or exceed V1 success rate on validated environments.
- Fallback-rate threshold is within agreed limit and trending down.
- Manual rollback drill completed successfully.
- A release readiness review approves standard-default promotion.

### Phase 4: V2 Standard Default, V1 Explicit Only

Scope:

- V2 is the standard default path.
- V1 remains available only through explicit selection or emergency rollback.

Entry criteria:

- Phase 3 exit criteria complete.

Supported:

- V2 as the normal supported engine.
- V1 only as explicit fallback for break-glass recovery, regulated environments, or unresolved compatibility gaps approved by the release owner.

Best-effort:

- Compatibility aliases and legacy flags still accepted where cheap to preserve.

Deprecated:

- V1 as a normal operating path.
- `--experience` alias family once V1 removal is scheduled.

Exit criteria:

- V1 usage drops below the agreed deprecation threshold for sustained releases.
- No supported pack/profile/method combination requires V1.
- Emergency rollback procedure has not been needed for a full deprecation observation window, or any incidents were resolved without reopening V1 as the default.
- Release, support, and operator stakeholders approve deprecation.

Testing gate to V1 deprecation:

- Final compatibility pass across supported packs, profiles, methods, and validated environments.
- Rollback drill still succeeds even though V1 is no longer the default.
- Documentation and support escalation paths are updated for a V2-first world.

## Support Policy by Phase

### V1

- Phase 0-2: fully supported and recommended.
- Phase 3: fully supported, but recommended primarily for fallback or unvalidated environments.
- Phase 4: supported only as explicit fallback and break-glass path.
- After deprecation trigger: no longer a generally supported install engine; retained only if the release owner explicitly extends the window.

### V2

- Phase 0: unsupported.
- Phase 1: preview support only; no SLA beyond best-effort engineering response.
- Phase 2: supported for explicit opt-in on validated environments.
- Phase 3: fully supported on validated environments where it is the default.
- Phase 4: primary supported engine.

### Legacy Selectors and Flags

- `--engine` is the canonical interface starting in Phase 1.
- `--experience` remains supported as a compatibility alias through Phase 4 unless an extension is required.
- Unknown flags routed to V1 may pass through when practical; unknown flags routed to V2 must fail clearly and suggest `--engine v1` if the workflow is still V1-only.

## Fallback Policy

### Allowed automatic fallback to V1

Automatic fallback is allowed only before V2 changes the target system:

- unsupported OS or architecture
- V2 binary download takes more than 5 seconds
- binary fetch fails
- SHA256 checksum verification fails
- required signature verification fails
- known fallback environment is detected
- emergency rollback toggle is enabled

Behavior:

- log the reason in dispatcher diagnostics
- continue with V1 silently from the end-user perspective unless an operator explicitly asked for V2
- if V2 was explicitly requested and fallback occurs, print a concise notice that V1 was used instead and why

### V2 failure after execution has started

Do not auto-fallback blindly once V2 may have modified state.

Required behavior:

- write JSON session state
- preserve logs and step status
- instruct the operator to choose one of:
  - `loki-installer status`
  - `loki-installer resume`
  - retry the failed step
  - run V1 only after confirming compatibility and cleanup requirements

### Fallback eligibility checks before switching to V1 after a partial V2 run

The operator must confirm:

- V2 did not leave an in-flight deploy action that V1 cannot safely reconcile
- shared metadata version is still compatible with V1
- target stack or host is in a state V1 knows how to inspect or repair
- rollback or cleanup instructions for the failed V2 step have been completed

If any of these checks fail, stay on V2 and use resume or targeted remediation.

## Testing Gates Between Phases

Minimum required evidence before advancing phases:

- unit tests: request parsing, routing, plan generation, metadata validation, deploy adapter validation
- integration tests: dispatcher routing, V2 fetch + verification, non-interactive happy path, fallback routing, resume logic, `status`
- compatibility tests: old command shapes, selector aliases, pack/profile/method resolution parity, shared metadata consumption by both engines
- manual validation: macOS, Linux, TTY, non-TTY, selected AWS auth flows, failed deploy recovery, emergency rollback drill

A phase may not advance if any of the following are true:

- a severity-1 defect is open
- a severity-2 defect affects the next phase's default path
- fallback routing is flaky or non-deterministic
- release artifact verification is bypassed
- support cannot diagnose failures from logs + session state + `status`

## V1 Deprecation Timeline and Conditions

V1 is not deprecated by calendar date alone. Deprecation requires both elapsed time and operational evidence.

Recommended timeline:

1. Enter Phase 4 and keep V1 explicitly available for at least two stable release cycles.
2. Announce V1 deprecation intent at the start of that observation window.
3. Keep `--engine v1` available throughout the window.
4. Remove normal documentation references to V1, except break-glass guidance.
5. Deprecate V1 only after all conditions below are satisfied.

Required conditions:

- V2 is the standard default for all supported environments.
- No supported install scenario still depends on V1.
- Fallback and rollback procedures are documented and tested.
- Support volume from V2 default installs is at or below the agreed threshold.
- Operator tooling, including `status`, is sufficient for first-line diagnosis.
- Stakeholders explicitly approve deprecation.

Removal sequence:

1. Mark V1 deprecated but still callable with `--engine v1`.
2. After one additional stable release cycle with no blocking regressions, remove `--engine v1` from user-facing docs.
3. Remove `--experience` aliases at the same time or later, depending on compatibility risk.
4. Only remove V1 code from the bootstrap path after the release owner signs off that emergency rollback no longer depends on it.

## Operator Runbook: Emergency Rollback to V1

Use this runbook when V2 introduces a broad regression, validation bug, artifact distribution issue, or support-impacting outage.

### Trigger conditions

- widespread V2 fetch or verification failures
- elevated install failure rate after default-routing changes
- severe interactive or non-interactive regression
- corrupted or unusable V2 session behavior across customers
- release artifact compromise or checksum/signature mismatch

### Immediate actions

1. Freeze further V2 promotion and open an incident.
2. Force V1 globally using the emergency rollback toggle in the dispatcher or release-side configuration.
3. Confirm the bootstrap path now routes `curl -sfL loki.run | bash` to V1 by default.
4. Leave `--engine v2` available only for controlled engineering validation, or disable it entirely if the incident warrants.
5. Notify support and operators that V1 is the active engine and that active V2 sessions should not be retried until cleared.

### Validation checklist

1. Run smoke installs on macOS and Linux.
2. Verify non-interactive V1 installs using representative `--pack`, `--profile`, and `--method` combinations.
3. Confirm old command shapes still succeed.
4. Confirm V2 download timeout and verification failures route deterministically to V1.
5. Confirm `status` can still inspect prior V2 session files for impacted users.

### Handling active V2 sessions

- Do not auto-convert partial V2 runs into V1 runs.
- First inspect with `loki-installer status`.
- If the environment is safe for V1 recovery, run V1 explicitly.
- If the environment is not safe for V1 recovery, keep the incident on V2 and use resume or targeted cleanup guidance.

### Exit from rollback mode

Rollback mode can be lifted only when:

- the incident root cause is identified
- the fix is released and verified
- staging and canary validation pass
- the release owner approves re-entry to the previous rollout phase, not automatic promotion to a later one

## Document Ownership

- Release owner: decides phase advancement and rollback activation
- Installer maintainers: own routing, artifact verification, session schema, and engine parity
- Support: owns operator-facing triage steps and validates `status` output against real incidents
