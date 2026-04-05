# Loki Installer V2 — Opus Code Review

**Date:** 2026-04-05
**Reviewer:** Opus (automated)
**Codebase:** `/tmp/loki-agent-v2/tools/loki-installer/`

---

## 1. CONTRACT COMPLIANCE — ⭐ Good

The Rust types in `src/core/contract.rs` are a **faithful 1:1 match** of the schemas in `installer-contract.md`.

### Verified matches:
- `InstallRequest` (L7-19): all 11 fields match, correct types ✅
- `InstallerEngine` (L21-26): V1/V2 with `rename_all = "snake_case"` ✅
- `InstallMode` (L28-33): Interactive/NonInteractive ✅
- `DeployMethodId` (L35-40): Cfn/Terraform with PartialOrd/Ord ✅
- `InstallPlan` (L51-65): all 12 fields match ✅
- `PrerequisiteCheck` (L67-74): all 5 fields ✅
- `PrerequisiteKind` (L76-87): all 8 variants ✅
- `DeployStep` (L89-95): 4 fields ✅
- `InstallPhase` (L97-109): all 9 variants ✅
- `DeployAction` (L128-138): all 7 variants with `tag = "type"` ✅
- `PlanWarning`, `PostInstallStep`, `SessionPersistenceSpec`, `SessionFormat` ✅
- `PackManifest` (L167-181): all 12 fields ✅
- `PostInstallActionId` (L183-188): SsmSession/Pairing ✅
- `PackOptionSpec`, `OptionValueType` ✅
- `ProfileManifest` (L206-217): all 8 fields ✅
- `MethodManifest` (L219-231): all 10 fields ✅
- `MethodOptionSpec` (L233-239) ✅
- `AdapterPlan` (L241-248): all 5 fields ✅
- `InstallSession` (L250-263): all 11 fields ✅
- `ApplyResult`, `UninstallResult`, `DeployStatus` ✅
- `AdapterValidationError` (L291-299): 3 variants match ✅
- `AdapterError` (L301-313): 5 variants match ✅
- `InstallEventSink` trait (L315-318) ✅
- `InstallEvent` enum (L320-346): all 6 variants with `tag = "type"` ✅
- `DeployAdapter` trait (L348-388): all 6 methods, signatures match ✅

**No deviations found.** Types, field names, serde attributes, and trait signatures are contract-compliant.

---

## 2. ARCHITECTURE — ⚠️ Needs Work

### Rating: Needs Work

**Problem: Single crate instead of workspace with 3 crates.**

The `tui-v2-architecture.md` specifies a Cargo workspace:
```
crates/
  loki-installer-core/
  loki-installer-cli/
  loki-installer-tui/
```

The actual code is a **single binary crate** with module directories (`src/core/`, `src/cli/`, `src/tui/`, `src/adapters/`). This means:
- **No compile-time enforcement** that core doesn't depend on TUI/CLI
- **No separate binaries** for CLI vs TUI
- TUI is always compiled even for headless use

### Dependency leaks found:

1. **`src/cli/commands/install.rs:3`** — `use crate::tui;` — CLI layer directly imports TUI to launch interactive mode. In the 3-crate design, the CLI binary would either invoke the TUI binary or the TUI crate would have its own `main.rs`.

2. **`src/adapters/` lives outside `src/core/`** — The contract says adapters belong in `loki-installer-core`. Currently they're a sibling module at `src/adapters/`, not under `src/core/`. The planner in `src/core/planner.rs:1` imports from `crate::adapters`, creating a circular-ish dependency direction.

3. **No `widgets/` module** — The architecture doc specifies `widgets/{checklist, hints, logs, progress, review_table}.rs`. These don't exist; all rendering is inline in screen modules and `runtime.rs`.

### What's correct:
- Core types are genuinely TUI-free (no ratatui imports in `src/core/`) ✅
- Screen modules only import from `core` and `tui::app` ✅
- The logical separation of concerns (contract, manifests, planner, session, doctor) is clean ✅

---

## 3. CODE QUALITY — ⭐ Good (with caveats)

### Error Handling: Good ✅
- No `.unwrap()` on fallible operations in production paths
- Proper `?` propagation throughout
- Custom error types with `thiserror` for `ManifestError`, `SessionError`, `PlannerError`, `AdapterError`, `AdapterValidationError`
- `color_eyre::Result` used at CLI boundaries
- One `.unwrap()` at `session.rs:82` on `serde_json::to_vec_pretty` for the `latest.json` pointer — safe in practice but inconsistent

### Async Correctness: Needs Work ⚠️
- **`src/tui/runtime.rs:32`** — `event::poll()` is a **blocking call** inside an async function. This blocks the tokio runtime thread. Should use `crossterm::event::EventStream` with `futures::StreamExt` instead.
- **`src/core/doctor.rs:25`** — `run_doctor` is synchronous (correct — no I/O that needs async), but `command_exists` at L149 does synchronous filesystem traversal. Fine for now but noted.
- **`src/core/planner.rs:37`** — `build_plan` is async only because adapters are async. The planner itself does no async work. This is acceptable design.
- Adapter `apply`/`resume` use `tokio::time::sleep` in stubs — correct for simulation.

### Dead Code / Unused Imports: Good ✅
- `src/core/session.rs:136-143`: `update_session_phase` and `touch_session` are defined but never called. Dead code.
- No other dead imports found.

### Serde Attributes: Good ✅
- All enums use `#[serde(rename_all = "snake_case")]` consistently
- Tagged enums (`DeployAction`, `InstallEvent`) use `#[serde(tag = "type")]` per contract
- Structs derive both `Serialize` and `Deserialize` where needed
- `DoctorReport` and `DoctorCheckResult` are missing `Serialize`/`Deserialize` — they're used in the JSON output path at `src/cli/commands/doctor.rs:12-20` but serialized manually via `serde_json::json!()`. This works but is fragile.

### Type Safety: Good ✅
- `DeployMethodId` is an enum, not a String ✅
- `InstallPhase` is an enum ✅
- `PrerequisiteKind` is an enum ✅
- Cursor indices are `usize` ✅
- `pack` field in `InstallRequest` is `String` where a newtype would add safety. Contract explicitly allows this.

### Naming Consistency: Good ✅
- Snake_case for fields, CamelCase for types throughout
- Minor: architecture doc says `pack_selection.rs`, code has `pack_select.rs`. Same for profile/method. Cosmetic.

---

## 4. TUI REVIEW — ⚠️ Needs Work

### Elm-style Update Loop: Mostly Correct ✅

**`src/tui/update.rs`** implements the pattern correctly:
- `update(state, event) -> Vec<AppAction>` is the only state mutator ✅
- Side effects happen only through `AppAction` ✅
- All async results come back as `InstallerEvent` variants ✅

**Issues:**
1. **`runtime.rs:91-103` (StartDeploy)** — The runtime handler mutates `state.session` directly (`state.session = Some(session)`) instead of flowing through `update`. This violates the Elm principle. The deploy result should come back as an event, not be directly assigned.

2. **`runtime.rs:57`** — Actions are popped from the back (`pending.pop()`), meaning actions are executed in **reverse order**. Since `update` returns `Vec<AppAction>` where the first action is presumably highest priority, this reversal is a bug. Should use `.drain(..)` or `.remove(0)` or reverse the vec.

3. **`update.rs:132`** — Catch-all `_ => vec![AppAction::Render]` silently swallows `SessionLoaded`, `StatusLoaded`, `QuitRequested`, and `NextRequested` events. These should be handled explicitly.

### All 8 Screens: Implemented ✅
- Welcome (`welcome.rs`) ✅
- DoctorPreflight (`preflight.rs`) ✅
- PackSelection (`pack_select.rs`) ✅
- ProfileSelection (`profile_select.rs`) ✅
- MethodSelection (`method_select.rs`) ✅
- Review (`review.rs`) ✅
- DeployProgress (`deploy.rs`) ✅
- PostInstall (`post_install.rs`) ✅

### Screen Transitions: Correct ✅
The `advance()` function at `update.rs:136-177` follows the spec flow:
Welcome → Doctor → Pack → Profile → Method → Review → Deploy → PostInstall

### Key Bindings: Partial ⚠️
| Spec | Implemented | Status |
|------|-------------|--------|
| Up/k | ✅ L35 | ✅ |
| Down/j | ✅ L31 | ✅ |
| Left → back | ✅ L30 | ✅ |
| Enter → advance | ✅ L29 | ✅ |
| b → back | ✅ L30 | ✅ |
| q → quit | ✅ L21 | ✅ |
| Ctrl+C → quit | ✅ L25 | ✅ |
| h → back | ❌ Not mapped | Missing |
| Space → toggle | ❌ Not implemented | Missing |
| Tab/Shift-Tab | ❌ Not implemented | Missing |
| r → retry | ❌ Not implemented | Missing |
| s → save/refresh | ❌ Not implemented | Missing |
| ? → help overlay | ❌ Not implemented | Missing |
| Esc → close modal | ❌ Not implemented | Missing |
| Right/l → next field | ❌ Not implemented | Missing |

### Layout: Partial ⚠️
- Left pane checklist: ✅ (`runtime.rs:126-148`) — 22-char wide, shows all 8 screens with `>` marker
- Main pane: ✅ — screen-specific content
- Bottom hints bar: ✅ (`runtime.rs:170-174`) — static text, not context-sensitive per spec
- **No modal support** — quit confirmation, error display, help overlay missing
- **No responsive collapse** — no handling for narrow terminals

---

## 5. ADAPTER REVIEW — ⭐ Good

### CfnAdapter (`src/adapters/cfn.rs`): Full trait implementation ✅
All 6 trait methods implemented:
- `method_id()` → `Cfn` ✅
- `validate_request()` — checks `requires_stack_name` ✅
- `build_plan()` — returns prerequisites, 4 deploy steps, adapter_options, post_install ✅
- `apply()` — delegates to stubbed runner ✅
- `resume()` — clones plan from session, delegates to stub ✅
- `uninstall()` — emits log, returns stub result ✅
- `status()` — reads from session artifacts ✅

### TerraformAdapter (`src/adapters/terraform.rs`): Full trait implementation ✅
All 6 trait methods implemented with appropriate Terraform-specific steps (init, plan, apply, health check).

### Stub Quality: Reasonable ✅
- Stubs simulate step-by-step execution with events
- Sleep durations are minimal (50ms) — good for testing
- Artifacts are populated (stack_name, stack_status, instance_health)
- Resume correctly requires session.plan to exist

---

## 6. MANIFEST REVIEW — 🔴 Broken

### No manifests exist.

The directories `packs/`, `profiles/`, `methods/` **do not exist** in the codebase at all. The `ManifestRepository::discover()` walks up from CWD looking for these directories, and the contract requires:

- `packs/<name>/manifest.yaml` for all 7 packs
- `profiles/<profile>.yaml`
- `methods/cfn.yaml` and `methods/terraform.yaml`

**Impact:** The installer cannot run at all without manifests. `Planner::discover()` will fail with `RepoRootNotFound` since no `packs/` directory exists. Every CLI command and TUI flow depends on manifest loading.

**Rating: Broken** — This is the single biggest blocker.

---

## 7. GAPS — What's Missing for v0.1

### Critical (blocks any use):

1. **No YAML manifests** — packs/, profiles/, methods/ directories and files don't exist. Nothing can run.

2. **No Cargo workspace** — Single crate instead of 3-crate workspace per architecture doc. Blocks independent compilation and binary separation.

3. **Blocking `event::poll()` in async runtime** (`runtime.rs:32`) — Will cause tokio starvation under load.

### High (functional gaps):

4. **Action execution order reversed** (`runtime.rs:57`) — `pending.pop()` processes actions LIFO instead of FIFO.

5. **Missing key bindings** — Space, Tab, r, s, ?, Esc, h, Right/l not handled.

6. **No modal/overlay system** — Quit confirmation, error display, help overlay missing.

7. **Swallowed events** (`update.rs:132`) — `SessionLoaded`, `StatusLoaded`, `QuitRequested`, `NextRequested` silently ignored.

8. **`plan` command not in architecture** — `src/cli/commands/plan.rs` and `src/cli/args.rs:63` add a `Plan` subcommand not in the architecture doc. Not harmful but undocumented.

9. **`uninstall` command not in architecture** — Same situation. The contract defines `DeployAdapter::uninstall` but the CLI doc only lists `install`, `doctor`, `resume`, `status`.

10. **No `--engine` flag routing** — The `EngineArg` is parsed but never used to dispatch between V1/V2 runtimes.

### Medium (quality/completeness):

11. **No tests** — Zero test files exist.

12. **No widgets module** — All rendering inline; no reusable `ChecklistWidget`, `HintsWidget`, `ModalWidget`, etc.

13. **`DoctorReport`/`DoctorCheckResult` not serializable** — Missing `Serialize`/`Deserialize` derives; JSON output works around this with manual `serde_json::json!()`.

14. **Context-sensitive hints** — Bottom bar is static ("Enter next | b back | q quit | arrows move") instead of changing per screen.

15. **No confirmation before deploy** — Review → Deploy transition happens on single Enter with no confirmation dialog.

16. **`DeploymentState` not populated during TUI deploy** — `runtime.rs:91-103` runs `planner.start_install()` synchronously and doesn't pipe `InstallEvent`s through the event loop. The deploy progress screen will always show empty.

17. **No log buffer bounds** — `DeploymentState.logs: Vec<String>` grows unbounded. Spec says "bounded buffers."

18. **No session resume detection on Welcome screen** — Spec says Welcome should surface resume option for unfinished sessions.

19. **Doctor screen doesn't block forward on failures** — `advance()` at `update.rs:139` always proceeds to `LoadPacks` regardless of doctor results. Spec says required check failures should block.

20. **`update_session_phase` and `touch_session` dead code** (`session.rs:136-143`).

---

## Prioritized Fix List

| Priority | Item | Effort | File(s) |
|----------|------|--------|---------|
| P0 | Create packs/, profiles/, methods/ with YAML manifests | Medium | New files |
| P0 | Fix action execution order (pop → drain/shift) | Trivial | `tui/runtime.rs:57` |
| P1 | Replace blocking `event::poll` with async EventStream | Small | `tui/runtime.rs:32` |
| P1 | Pipe deploy events through TUI event loop | Medium | `tui/runtime.rs:91-103` |
| P1 | Handle swallowed events (SessionLoaded, etc.) | Small | `tui/update.rs:132` |
| P1 | Block doctor → packs when required checks fail | Small | `tui/update.rs:139` |
| P2 | Split into 3-crate Cargo workspace | Large | Cargo.toml, all src/ |
| P2 | Add missing key bindings (Space, Tab, r, s, ?, Esc, h) | Medium | `tui/update.rs` |
| P2 | Add modal/overlay system (quit confirm, errors, help) | Medium | New `tui/widgets/` |
| P2 | Add basic integration tests | Medium | New `tests/` |
| P2 | Context-sensitive bottom hints | Small | `tui/runtime.rs:170-174` |
| P3 | Extract reusable widgets module | Medium | `tui/screens/*`, new `tui/widgets/` |
| P3 | Add Serialize/Deserialize to DoctorReport types | Trivial | `core/doctor.rs:4-5,11-12` |
| P3 | Add log buffer bounds | Trivial | `tui/app.rs:62` |
| P3 | Session resume detection on Welcome | Small | `tui/update.rs`, `tui/screens/welcome.rs` |
| P3 | Deploy confirmation dialog | Small | `tui/update.rs:170-173` |
| P3 | Remove dead code (update_session_phase, touch_session) | Trivial | `core/session.rs:136-143` |
| P3 | Responsive terminal collapse for narrow width | Medium | `tui/runtime.rs` |

---

## Summary

| Area | Rating |
|------|--------|
| Contract Compliance | ⭐ Good — exact match |
| Architecture | ⚠️ Needs Work — single crate, no workspace |
| Code Quality | ⭐ Good — clean error handling, minor issues |
| TUI | ⚠️ Needs Work — core loop works, many features missing |
| Adapters | ⭐ Good — full trait impl, reasonable stubs |
| Manifests | 🔴 Broken — none exist |
| Overall | **Solid foundation, not runnable** |

The contract types are exceptionally well-implemented — every field, enum, trait method matches the spec exactly. The code quality is high with proper error types and no dangerous unwraps. The main gaps are infrastructure (no manifests, no workspace split) and TUI completeness (missing keybindings, modals, event piping). The P0 fix (creating manifests) would make the CLI path functional; the TUI needs the P0+P1 fixes to be usable.
