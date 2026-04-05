# Loki Agent Installer V2 Design

## Objective

Design a new **Installer V2** for Loki Agent that:

- preserves backward compatibility with the current installer experience
- supports both **interactive** and **non-interactive** modes
- allows users to explicitly choose **V1** or **V2** from the existing installer entrypoint
- enables V2 to be built and rolled out **in parallel** without breaking existing users
- keeps the public install flow stable while improving architecture, recovery, and extensibility

---

## Goals

1. Keep the public install entrypoint stable:
   - `curl -sfL loki.run | bash`
2. Preserve the current mental model for non-interactive installs:
   - pack selection
   - profile selection
   - deploy method selection
   - yes/non-interactive mode
3. Add a parallel **V2** path without removing or destabilizing **V1**
4. Support both:
   - full-screen interactive TUI
   - headless/non-interactive execution
5. Establish a shared install contract so V1 and V2 do not drift over time
6. Support future expansion:
   - more packs
   - more deployment methods
   - better resume/retry
   - richer diagnostics

---

## Non-Goals

- Exact flag parity forever between V1 and V2
- Rewriting all existing deployment logic at once
- Replacing V1 immediately
- Making the installer generic for unrelated projects

---

## Current Constraints

Loki Agent already has a user-facing installer experience and repo structure that V2 must respect.

Relevant current characteristics:

- public install bootstrap via `loki.run`
- interactive and non-interactive install flows
- dynamic pack discovery
- multiple deployment methods
- repo structure already includes:
  - `install.sh`
  - `uninstall.sh`
  - `deploy/`
  - `packs/`
  - `profiles/`

Because installer behavior is tightly coupled to repo contents, V2 should be built **in the same repo** and not as a separate product.

Sources:
- https://github.com/inceptionstack/loki-agent
- https://raw.githubusercontent.com/inceptionstack/loki-agent/main/install.sh

---

## High-Level Architecture

Use a **dual-engine installer** behind one stable bootstrap entrypoint.

```text
Public Entry Point
    |
    v
install.sh (dispatcher/bootstrap)
    |
    +--> V1 engine (existing bash installer)
    |
    +--> V2 engine (new installer binary)
            |
            +--> interactive TUI mode
            +--> non-interactive headless mode
```

The central principle is:

**One stable public entrypoint, two install experiences, one shared install contract.**

---

## Public Entry Point

This remains stable:

```bash
curl -sfL loki.run | bash
```

And the non-interactive shape remains recognizable:

```bash
curl -sfL loki.run | bash -s -- -y --pack openclaw --profile builder --method cfn
```

We do not need exact flag parity forever, but we should preserve the core install model.

---

## Experience Selection

Add explicit experience selection to the bootstrap script.

### Supported experience selectors

- `--experience v1`
- `--experience v2`

Optional alias:

- `--legacy` → `--experience v1`

Optional environment override:

- `LOKI_INSTALLER_EXPERIENCE=v1`
- `LOKI_INSTALLER_EXPERIENCE=v2`

### Routing policy

`install.sh` becomes a **dispatcher**:

```text
install.sh
  ├── if --experience v1 -> run V1
  ├── if --experience v2 -> run V2
  ├── if env override set -> honor it
  └── else use default rollout policy
```

---

## Rollout Policy

### Phase 0
- V1 only

### Phase 1
- Dispatcher introduced
- default remains V1
- `--experience v2` available
- V2 documented as preview/opt-in

### Phase 2
- V2 supports:
  - doctor
  - preflight
  - non-interactive happy path
  - interactive happy path
- default still V1

### Phase 3
- default to V2 on validated environments
- automatically fall back to V1 when needed

### Phase 4
- V2 becomes standard default
- V1 remains available through explicit selection
- later deprecate V1 when safe

---

## Environment-Based Routing

The dispatcher should prefer **V2** when:

- supported OS/architecture
- binary download succeeds
- checksum/signature verification succeeds
- terminal is suitable for interactive mode, or non-interactive args are sufficient
- user did not explicitly request V1

The dispatcher should prefer **V1** when:

- `--experience v1` is supplied
- platform is unsupported for V2
- binary fetch or verification fails
- a known fallback environment is detected
- emergency rollback toggle is enabled

This minimizes rollout risk.

---

## Core Design Principle: Shared Install Contract

V1 and V2 must not independently invent install behavior.

Both should conceptually operate on the same request/plan model.

### InstallRequest

```text
InstallRequest
  experience
  mode                # interactive | non_interactive
  pack
  profile
  method
  region
  stack_name
  auto_yes
  extra_options
```

### InstallPlan

```text
InstallPlan
  resolved_pack
  resolved_profile
  resolved_method
  prerequisites
  deploy_steps
  warnings
  post_install_steps
```

This is the key mechanism that prevents drift between the legacy and new installers.

---

## V1 Responsibilities

V1 remains the conservative and stable fallback.

Use V1 for:

- existing users
- rollback safety
- environments not yet validated for V2
- emergency fallback if V2 cannot run

V1 should continue working with minimal disruption.

---

## V2 Responsibilities

V2 is a new installer engine delivered as a standalone binary.

It supports:

- **interactive TUI mode**
- **non-interactive CLI mode**

Example commands inside the binary:

```bash
loki-installer install
loki-installer install --non-interactive --pack openclaw --profile builder --method cfn
loki-installer doctor
loki-installer plan
loki-installer resume
loki-installer uninstall
```

---

## Recommended V2 Implementation Stack

### Language / Runtime

- **Rust**

### TUI

- **Ratatui**

### Terminal backend

- **Crossterm**

### CLI argument parsing

- **Clap**

### Async runtime

- **Tokio**

### State model

- reducer/event-loop architecture

### Persistence

- JSON or SQLite-based local session state

### Deployment orchestration

- subprocess wrappers around:
  - AWS CLI
  - CloudFormation
  - Terraform
  - future deploy methods as needed

Reasoning:
- standalone binary
- no Node or Python prerequisite
- reliable terminal behavior
- good fit for preflight + deployment workflows
- clean split between UI and installer core

---

## V2 Internal Layers

V2 should be split into three main layers.

### 1. Installer Core

Pure business logic, no TUI concerns.

Responsibilities:

- OS/architecture detection
- AWS credential validation
- caller identity detection
- region detection
- preflight checks
- config gathering/validation
- plan generation
- deployment execution
- session persistence
- resume/retry support

### 2. Headless CLI

Exposes deterministic non-interactive functionality.

Commands:

- `install`
- `doctor`
- `plan`
- `resume`
- `uninstall`

This is important for:
- CI/CD
- automation
- SSH workflows
- advanced users who do not want a TUI

### 3. TUI Frontend

A thin frontend over the same installer core.

Screens:

- Welcome
- Doctor / preflight
- Pack selection
- Profile selection
- Deployment method selection
- Review plan
- Deploy progress
- Post-install instructions

---

## Interactive vs Non-Interactive Modes

### Interactive Mode

The TUI wizard handles:

1. preflight checks
2. pack selection
3. profile selection
4. deployment method selection
5. plan review
6. deployment progress
7. completion and next steps

### Non-Interactive Mode

The binary should also support deterministic headless installs.

Rules:

- missing required inputs → fail fast with actionable errors
- optional values → infer defaults where safe
- `-y` / `--yes` means accept defaults where safe
- optional `--json` output for machine-readable consumption

This preserves the current automation-friendly installer model.

---

## Bootstrap Compatibility Layer

The bootstrap script should map old-style flags into the new request model.

### Examples

- `-y`
- `--yes`
- `--non-interactive`
  → `mode=non_interactive`, `auto_yes=true`

- `--pack`
  → `pack`

- `--profile`
  → `profile`

- `--method`
  → `method`

Possible normalization:

- `tf` → `terraform`
- `cfn` → `cfn`

### Unknown flags

If routed to V1:
- pass through if possible

If routed to V2:
- translate if known
- otherwise fail clearly and suggest `--experience v1` if needed

---

## Pack / Profile / Method Metadata

Because Loki’s installer behavior depends on repo contents, the installer should rely on machine-readable metadata rather than hardcoded values in multiple places.

Recommended structure:

```text
installer/manifests/
  packs/
  profiles/
  methods/
```

Example pack manifest:

```yaml
name: openclaw
display_name: OpenClaw
experimental: false
allowed_profiles:
  - builder
  - account_assistant
supports:
  - cfn
  - terraform
default_region: us-east-1
post_install:
  - ssm_session
  - pairing
```

### Benefits

- one source of truth
- both V1 and V2 can consume the same metadata
- docs can be generated
- future packs become easier to add
- dynamic discovery remains intact

---

## Deployment Adapter Model

Do not couple deployment logic to the TUI.

Use deploy adapters with a stable interface.

```text
DeployAdapter
  validate(request)
  plan(request)
  apply(request, event_sink)
  resume(session)
  uninstall(target)
```

Initial implementations:

- `CfnAdapter`
- `TerraformAdapter`

Future:
- additional methods as needed

This keeps deploy behavior modular and testable.

---

## State Model

Use an event-driven reducer architecture.

### Core model

```text
AppState
InstallerEvent
AppAction
update(state, action) -> state + effects
```

Why:

- predictable transitions
- easier background task handling
- better testing
- clean retry/resume support
- avoids terminal/UI logic bleeding into install logic

---

## Session Persistence and Resume

A major V2 improvement should be persistence and resumability.

Example persisted session:

```json
{
  "installer_version": "2.x",
  "experience": "v2",
  "mode": "interactive",
  "request": {
    "pack": "openclaw",
    "profile": "builder",
    "method": "cfn"
  },
  "resolved": {
    "region": "us-east-1",
    "stack_name": "my-loki"
  },
  "phase": "deploy_stack",
  "artifacts": {
    "stack_id": "...",
    "instance_id": "..."
  }
}
```

### Benefits

- resume interrupted installs
- retry failed phases
- provide better diagnostics
- support “show me what happened” workflows

---

## UX Design for the TUI

Recommended TUI layout:

### Left pane
Phase checklist:

- Environment
- AWS Auth
- Pack
- Profile
- Method
- Review
- Deploy
- Finish

### Main pane
Context-dependent content:

- forms
- warnings
- summaries
- live deployment progress
- post-install steps

### Bottom hint bar
Examples:

- `Enter` confirm
- `Space` toggle
- `Tab` next
- `d` details
- `l` logs
- `r` retry
- `q` quit

### Progress behavior

Use **phase-based progress** rather than fake percentages.

Examples:

- Validating environment
- Discovering AWS context
- Preparing deployment
- Creating stack
- Waiting for resources
- Finalizing agent

This is more honest and useful for infrastructure installs.

---

## Repo Layout

Recommended repo structure:

```text
loki-agent/
├── install.sh                     # bootstrap dispatcher
├── uninstall.sh
├── scripts/
│   ├── install-v1.sh             # existing installer logic
│   ├── common.sh
│   └── compatibility.sh
├── installer/
│   ├── manifests/
│   │   ├── packs/
│   │   ├── profiles/
│   │   └── methods/
│   ├── core/
│   ├── tui-v2/                   # Rust binary project
│   └── tools/
│       └── generate-docs
├── packs/
├── profiles/
├── deploy/
└── docs/
    ├── installer-v1.md
    ├── installer-v2.md
    └── migration.md
```

---

## install.sh Responsibilities After Refactor

The new `install.sh` should be intentionally small.

Responsibilities:

- parse minimal stable flags
- determine requested experience
- decide whether V2 can run
- fetch/verify V2 binary when selected
- route to V1 when needed
- provide clear error/fallback behavior

It should **not** continue to be the place where all install business logic lives.

---

## Failure and Fallback Strategy

### V2 failure before execution
If binary fetch or validation fails:
- log reason
- fall back to V1 when safe

### V2 failure during execution
If V2 has started and fails:
- preserve session state
- print next-step guidance
- allow:
  - retry
  - resume
  - fallback to V1 if compatible

### Emergency rollback
Provide a simple mechanism to force V1 globally during rollout, such as:
- environment toggle
- release-side configuration
- bootstrap-side default override

---

## Testing Strategy

### Unit tests
- request parsing
- plan generation
- metadata validation
- deploy adapter validation

### Integration tests
- V1 dispatcher routing
- V2 binary fetch + verification
- non-interactive happy path
- fallback routing
- resume logic

### Compatibility tests
- old command shapes still route correctly
- pack/profile/method resolution matches expectations
- V1 and V2 consume the same metadata

### Manual validation
- macOS
- Linux
- TTY and non-TTY environments
- selected AWS auth scenarios
- failed deploy recovery

---

## Migration Strategy

### Step 1
Refactor `install.sh` into a dispatcher while keeping V1 behavior intact.

### Step 2
Introduce V2 binary with:
- `doctor`
- preflight
- pack/profile/method resolution
- non-interactive install
- interactive wizard

### Step 3
Store metadata in shared manifests.

### Step 4
Move V1 to consume shared metadata where practical.

### Step 5
Progressively flip defaults to V2 on validated environments.

### Step 6
Keep V1 available until confidence is high enough to deprecate it.

---

## What Not To Do

- do not replace V1 immediately
- do not make users adopt a brand new public entrypoint first
- do not hardcode pack/profile/method lists in two places
- do not let TUI code own deployment logic
- do not scrape bash output as the long-term integration strategy
- do not tie rollout success to exact flag parity

---

## Recommended Final Direction

Build **Installer V2** as a new standalone binary inside the same repo, place it behind the existing `install.sh` entrypoint, add an explicit `--experience v1|v2` selector, preserve recognizable non-interactive usage, and make both installers rely on a shared install contract plus shared metadata.

That gives Loki:

- safe parallel rollout
- backward compatibility
- stable public install UX
- interactive and headless support
- clean extensibility for packs and deploy methods
- better recovery, diagnostics, and future maintainability

---

## Suggested Next Documents

After this document, the next useful artifacts would be:

1. `migration.md`
   - rollout phases
   - support policy
   - fallback policy

2. `installer-contract.md`
   - `InstallRequest`
   - `InstallPlan`
   - manifest schema
   - deploy adapter interfaces

3. `bootstrap-dispatcher.md`
   - exact routing logic
   - flag mapping
   - fallback decision table

4. `tui-v2-architecture.md`
   - Rust crate layout
   - event model
   - persistence format
   - screen flow
