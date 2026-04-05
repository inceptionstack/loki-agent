# Loki Installer V2 TUI Architecture

## Objective

Define the Rust TUI architecture for Installer V2 so that:

- interactive TUI and headless CLI share the same planning and execution core
- UI state is deterministic and testable through an Elm-style update loop
- session persistence remains JSON-only
- `status` and `resume` work from the same persisted session contract
- the screen flow stays aligned with the shared installer contract in `installer-contract.md`

This document assumes the accepted review deltas are already in force:

- engine selector is `--engine v1|v2`
- pack manifests live at `packs/<name>/manifest.yaml`
- session persistence is JSON-only
- `loki-installer status` is a required command

---

## Workspace Layout

Target end-state: a Cargo workspace with three crates.

Implementation note: the current repository intentionally remains a single `loki-installer`
crate with `core`, `cli`, `tui`, and `adapters` modules. That is an acceptable staging point
while the installer is still evolving quickly because it keeps refactors, tests, and release
plumbing simpler. The split becomes worth doing when one of these is true:

- the CLI and TUI need independent binaries or release cadences
- compile time or dependency isolation becomes a real problem
- the current module boundaries start leaking TUI or CLI concerns into `core`

Until then, preserve the dependency discipline described below inside the single crate and treat
the workspace layout as the extraction plan rather than an immediate requirement.

Use a Cargo workspace with three crates once that extraction pressure exists:

```text
installer/
  Cargo.toml                      # workspace root
  crates/
    loki-installer-core/
      Cargo.toml
      src/
        lib.rs
        contract.rs
        manifests.rs
        planner.rs
        session.rs
        doctor.rs
        adapters/
          mod.rs
          cfn.rs
          terraform.rs
    loki-installer-cli/
      Cargo.toml
      src/
        main.rs
        args.rs
        commands/
          install.rs
          doctor.rs
          status.rs
          resume.rs
    loki-installer-tui/
      Cargo.toml
      src/
        main.rs
        app.rs
        events.rs
        update.rs
        runtime.rs
        screens/
          mod.rs
          welcome.rs
          doctor.rs
          pack_selection.rs
          profile_selection.rs
          method_selection.rs
          review.rs
          deploy_progress.rs
          post_install.rs
        widgets/
          mod.rs
          checklist.rs
          hints.rs
          logs.rs
          progress.rs
          review_table.rs
```

### Crate responsibilities

- `loki-installer-core`
  - Source of truth for contract types from `installer-contract.md`
  - Manifest loading from `packs/<name>/manifest.yaml`, `profiles/`, and `methods/`
  - Planner, doctor/preflight logic, adapter traits, session persistence, and provider status lookup
  - No Ratatui or terminal dependencies
- `loki-installer-cli`
  - Parses CLI args
  - Normalizes input into `InstallRequest`
  - Runs non-interactive commands such as `install`, `doctor`, `resume`, and `status`
  - Renders plain text or JSON output
- `loki-installer-tui`
  - Owns terminal setup, input loop, rendering, and async event bridging
  - Converts user input and background progress into `InstallerEvent`
  - Uses `loki-installer-core` for all planning, persistence, and deployment behavior

### Dependency direction

```text
loki-installer-core   <- no dependency on CLI or TUI
loki-installer-cli    -> depends on core
loki-installer-tui    -> depends on core
```

This keeps the TUI thin and prevents execution rules from drifting away from the headless path.

---

## Elm-Style Event Model

The TUI uses a single state tree and a pure-ish update loop:

```text
terminal input / async adapter events / timer ticks
    -> InstallerEvent
    -> update(AppState, InstallerEvent) -> Vec<AppAction>
    -> runtime executes AppAction side effects
    -> resulting events fed back into update(...)
```

### AppState

`AppState` is the full in-memory model for the TUI.

```rust
pub struct AppState {
    pub screen: ScreenId,
    pub lifecycle: AppLifecycle,
    pub request_draft: InstallRequestDraft,
    pub doctor: DoctorState,
    pub plan: Option<InstallPlan>,
    pub session: Option<InstallSession>,
    pub deployment: DeploymentState,
    pub ui: UiState,
    pub errors: Vec<UserFacingError>,
}
```

Suggested sub-structures:

- `ScreenId`
  - `Welcome`
  - `DoctorPreflight`
  - `PackSelection`
  - `ProfileSelection`
  - `MethodSelection`
  - `Review`
  - `DeployProgress`
  - `PostInstall`
- `InstallRequestDraft`
  - mutable selections before a fully valid `InstallRequest` exists
  - fields mirror `InstallRequest` plus per-screen cursor state
- `DoctorState`
  - ordered check list
  - current run status
  - remediation text for failures
- `DeploymentState`
  - current phase
  - step statuses keyed by stable `deploy_steps[*].id`
  - live logs
  - progress ratio
  - post-install messages
- `UiState`
  - focused panel
  - keyboard hint mode
  - confirmation modal state
  - transient toast/error banner state

### InstallerEvent

`InstallerEvent` is the only input to `update`.

```rust
pub enum InstallerEvent {
    AppStarted,
    Tick,
    KeyPressed(KeyEvent),
    Resize { width: u16, height: u16 },

    PacksLoaded(Result<Vec<PackManifest>, String>),
    ProfilesLoaded(Result<Vec<ProfileManifest>, String>),
    MethodsLoaded(Result<Vec<MethodManifest>, String>),
    DoctorCompleted(Result<DoctorReport, String>),
    PlanBuilt(Result<InstallPlan, String>),
    SessionLoaded(Result<InstallSession, String>),

    InstallEventReceived(InstallEvent),
    DeployFinished(Result<ApplyResult, String>),
    StatusLoaded(Result<DeployStatus, String>),

    BackRequested,
    NextRequested,
    QuitRequested,
    ErrorAcknowledged,
}
```

Notes:

- `InstallEventReceived(InstallEvent)` wraps the contract-level execution events already defined in `installer-contract.md`
- all async work completes by posting an `InstallerEvent`; background tasks do not mutate `AppState` directly
- key handling should translate raw terminal input into semantic actions early where practical

### AppAction

`AppAction` describes side effects requested by `update`.

```rust
pub enum AppAction {
    Render,
    LoadPacks,
    LoadProfiles { pack_id: String },
    LoadMethods { pack_id: String, profile_id: Option<String> },
    RunDoctor { draft: InstallRequestDraft },
    BuildPlan { draft: InstallRequestDraft },
    StartDeploy { plan: InstallPlan },
    ResumeDeploy { session_id: String },
    PersistSession,
    LoadSession { session_id: String },
    LoadStatus { session_id: String },
    SwitchScreen(ScreenId),
    ShowError(String),
    Exit,
}
```

### `update` function

Signature:

```rust
pub fn update(state: &mut AppState, event: InstallerEvent) -> Vec<AppAction>
```

Rules:

- `update` is the only place that mutates `AppState`
- `update` must be deterministic for a given prior state and event
- side effects such as filesystem I/O, AWS calls, adapter execution, and terminal exit happen only through `AppAction`
- state mutations must be valid even if actions fail later
- persisted session writes should happen at stable boundaries:
  - after plan creation
  - after phase changes
  - after artifact updates
  - after final success/failure state changes

This makes the TUI replayable in tests and keeps it consistent with the CLI runtime.

---

## JSON Session Persistence

Review note 2 applies directly: use JSON only, no SQLite.

### Persistence goals

- support `resume` without replaying already completed stable phases
- support `loki-installer status`
- keep the file easy for support engineers to inspect
- avoid extra native dependencies and cross-compilation pain

### File shape

Persist the contract `InstallSession` from `loki-installer-core`, serialized with `serde_json`.

Suggested path layout:

```text
~/.local/state/loki-installer/sessions/<session_id>.json
```

Suggested file contents:

- `session_id`
- `installer_version`
- `engine`
- `mode`
- `request`
- `plan`
- `phase`
- `started_at`
- `updated_at`
- `artifacts`
- `status_summary`

### Persistence behavior

- write atomically with `tmp` file + rename
- one session file per install run
- latest-session symlink or pointer file is optional convenience, not source of truth
- TUI and CLI both use the same `session.rs` helpers in `loki-installer-core`
- status and resume locate sessions by explicit `session_id` first, then optionally by latest session

### Why JSON is sufficient

- the state is small and flat
- there is no need for concurrent multi-writer queries
- support teams benefit from a readable file format
- it matches the contract requirement that session files be sufficient for `resume` and `status`

---

## Screen Flow

The TUI is a guided wizard with exactly one forward path and explicit back navigation until deployment begins.

```text
Welcome
  -> Doctor / Preflight
  -> Pack selection
  -> Profile selection
  -> Method selection
  -> Review
  -> Deploy progress
  -> Post-install
```

### 1. Welcome

Purpose:

- explain what Installer V2 will do
- surface resume option if a recent unfinished session exists
- let the user continue, resume, or quit

Primary outputs:

- initialize `InstallRequestDraft`
- optionally choose an existing session to resume

### 2. Doctor / Preflight

Purpose:

- run environment checks before the user spends time configuring choices
- surface missing tools, unsupported OS/arch, AWS auth issues, and network reachability

Behavior:

- show checks in-progress and completed states
- allow retry after remediation
- block forward navigation on required check failures
- warnings may allow continue if the plan can still succeed safely

### 3. Pack Selection

Purpose:

- list available packs discovered from `packs/<name>/manifest.yaml`
- display pack description, experimental flag, supported methods, and default profile

Behavior:

- selecting a pack updates draft defaults
- moving forward triggers profile loading constrained by the selected pack

### 4. Profile Selection

Purpose:

- choose one profile allowed by the selected pack

Behavior:

- show profile display name, description, default region, and any config notes
- preselect pack default profile when present
- support skipping only if the profile resolves automatically and the user confirms it

### 5. Method Selection

Purpose:

- choose deployment method for the chosen pack/profile pair

Behavior:

- show method description, required tools, resume support, and whether stack name is required
- collect any required method-specific options
- infer defaults from pack/profile manifests where possible

### 6. Review

Purpose:

- present the resolved install request and generated plan before making changes

Contents:

- pack, profile, method, region, stack name
- prerequisite summary
- deploy step list
- warnings
- post-install actions expected after success

Behavior:

- `Enter` starts deploy
- `b` or left arrow returns to prior selection screens
- starting deploy persists the session immediately with the chosen plan

### 7. Deploy Progress

Purpose:

- show live execution state driven by adapter `InstallEvent`s

Contents:

- active phase
- current step
- historical completed steps
- log stream
- latest artifacts and status summary

Behavior:

- no backward navigation after remote mutation begins
- user may quit the TUI while deployment continues only if the adapter/runtime supports safe detach
- on failure, remain on this screen with retry/resume guidance
- on success, transition automatically to Post-install

### 8. Post-install

Purpose:

- present outcome and next steps

Contents:

- deployed pack/profile/method
- stack name and region if applicable
- instance health or deployment health summary
- post-install instructions such as SSM session or pairing steps
- exact `status` and `resume` command examples

Behavior:

- allow copy-friendly command display
- allow exit without losing persisted state

---

## TUI Layout

Use a stable three-region layout on all wizard screens:

```text
+----------------------+-------------------------------------------+
| Checklist            | Main pane                                 |
|                      |                                           |
| 1 Welcome            | Screen-specific content                   |
| 2 Doctor             | lists / forms / review / logs             |
| 3 Pack               |                                           |
| 4 Profile            |                                           |
| 5 Method             |                                           |
| 6 Review             |                                           |
| 7 Deploy             |                                           |
| 8 Post-install       |                                           |
+----------------------+-------------------------------------------+
| Hints: Enter next | b back | r retry | q quit | arrows move     |
+---------------------------------------------------------------+
```

### Left pane checklist

- fixed-width navigation/status column
- shows all screens in order
- each item is one of:
  - not started
  - current
  - completed
  - blocked
- during deployment, checklist items map to phases and step progress

### Main pane

- primary interaction area
- content changes by screen
- should prefer one dominant task per screen
- modal confirmations appear centered over this pane

### Bottom hints bar

- always visible
- shows context-sensitive key bindings for the current screen
- keeps discoverability high without cluttering the main content

### Responsive behavior

- below a minimum width, collapse the checklist into a top summary row
- log panes should truncate horizontally rather than wrapping aggressively
- minimum supported terminal size should be enforced with a resize warning screen if needed

---

## Key Bindings

The default bindings should be conservative and discoverable:

- `Up` / `k`
  - move selection up
- `Down` / `j`
  - move selection down
- `Left` / `h`
  - previous field or previous screen where allowed
- `Right` / `l`
  - next field where applicable
- `Tab`
  - cycle focus between interactive controls
- `Shift-Tab`
  - reverse focus
- `Enter`
  - confirm selection / continue / start deploy
- `Space`
  - toggle checkboxes or select highlighted option
- `b`
  - go back one screen before deployment starts
- `r`
  - retry doctor or failed async load on applicable screens
- `s`
  - save or refresh session/status details on deployment screens
- `q`
  - quit; requires confirmation if an install is in progress
- `?`
  - expand the key help overlay
- `Esc`
  - close modal or help overlay

Constraints:

- avoid single-key destructive actions
- do not reuse `q` for back navigation
- once deployment has started, `b` must not imply rollback

---

## `status` Command

Review note 6 requires a first-class `status` command:

```bash
loki-installer status [--session <session_id>] [--json]
```

### Responsibilities

- load the persisted JSON session file
- identify the deployment adapter from `session.plan` or `session.request.method`
- call `DeployAdapter::status(&InstallSession) -> DeployStatus`
- show both persisted context and live deployment/provider status

### Output requirements

Human-readable output should show:

- whether anything is deployed
- pack
- profile
- method
- region
- stack name
- stack status
- instance health
- last updated time

JSON output should serialize `DeployStatus` directly or wrap it with session metadata if needed for support tooling.

### Relationship to the TUI

- Post-install screen should print the exact `status` command for the current session
- Deploy Progress screen may internally refresh status data using the same core function
- `status` must work without launching the TUI

This keeps support workflows scriptable and does not require terminal interactivity to inspect an install.

---

## Ratatui Widget Structure

The TUI should compose a small set of reusable widgets rather than embedding layout logic directly into each screen.

### Root frame composition

- `ChecklistWidget`
  - renders the left pane progress list
- `MainScreenWidget`
  - screen-specific content container
- `HintsWidget`
  - renders bottom key hints
- `ModalWidget`
  - optional overlay for quit confirmation, errors, and help

### Screen widgets

- `WelcomeScreen`
  - intro copy
  - resume-session list if present
- `DoctorScreen`
  - `CheckList` plus remediation/details panel
- `PackSelectionScreen`
  - selectable pack list plus manifest detail panel
- `ProfileSelectionScreen`
  - selectable profile list plus details
- `MethodSelectionScreen`
  - selectable method list plus options form
- `ReviewScreen`
  - summary table, warning block, deploy step preview
- `DeployProgressScreen`
  - progress gauge, phase list, log tail, artifact summary
- `PostInstallScreen`
  - result summary and command block

### Lower-level Ratatui primitives

Expected Ratatui building blocks:

- `Layout`
  - split root frame into left, main, and bottom areas
- `Block`
  - titled borders for all major panels
- `List` / `ListState`
  - packs, profiles, methods, session resume list, doctor checks
- `Table`
  - review summary and artifact/status snapshots
- `Paragraph`
  - descriptions, remediation text, help text, logs
- `Gauge`
  - deployment phase completion
- `Tabs` or styled list
  - optional screen step indicator when checklist collapses on narrow terminals
- `Clear`
  - modal underlay cleanup

### Rendering rules

- rendering must be a pure projection of `AppState`
- widget code must not perform I/O
- step status colors and icons must come from stable semantic enums, not ad hoc string matching
- log widgets should consume bounded buffers to avoid unbounded memory growth

---

## Runtime Integration

The runtime layer in `loki-installer-tui` should bridge async work into the Elm loop:

- terminal input task
  - converts crossterm events into `InstallerEvent`
- background worker task
  - executes `AppAction` items such as manifest loading, doctor runs, plan building, deploy start, and status refresh
- adapter event bridge
  - maps `InstallEventSink` callbacks into `InstallerEvent::InstallEventReceived`
- persistence hook
  - writes updated `InstallSession` JSON through `loki-installer-core::session`

This keeps the update loop synchronous from the app’s point of view even while deployment work is asynchronous underneath.

---

## Compatibility Rules

- TUI never bypasses `InstallRequest`, `InstallPlan`, or `InstallSession`
- deployment progress is driven by the same `InstallEvent` contract used by CLI flows
- `status` and `resume` read the same JSON session files written during interactive runs
- pack, profile, and method resolution must come only from the shared manifests and planner in `loki-installer-core`
- if a feature cannot be represented in the core contract, it does not belong only in the TUI

This ensures the TUI remains a view/controller layer over the shared installer engine, not a second installer implementation.
