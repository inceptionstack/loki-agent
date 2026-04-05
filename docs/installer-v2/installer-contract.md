# Installer V2 Contract

This document defines the shared installer contract for Loki Agent V1/V2 compatibility and for the V2 Rust implementation. The types below are the source-of-truth contract surface for:

- install request parsing
- install plan generation
- shared metadata manifests
- deployment adapter integration

Review-note adjustments incorporated here:

- engine selector is `v1 | v2`, surfaced as `--engine`, not `--experience`
- pack manifests live at `packs/<name>/manifest.yaml`
- session persistence is JSON-only

## Rust Conventions

- Serialization: `serde::{Serialize, Deserialize}`
- Maps: `std::collections::BTreeMap<String, String>`
- Timestamps: `chrono::DateTime<chrono::Utc>`
- Paths: `std::path::PathBuf`
- Versions and identifiers remain plain `String` unless validation requires a dedicated newtype later

## InstallRequest Schema

`InstallRequest` is the canonical input contract passed from bootstrap parsing into planning and execution.

```rust
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InstallRequest {
    pub engine: InstallerEngine,
    pub mode: InstallMode,
    pub pack: String,
    pub profile: Option<String>,
    pub method: Option<DeployMethodId>,
    pub region: Option<String>,
    pub stack_name: Option<String>,
    pub auto_yes: bool,
    pub json_output: bool,
    pub resume_session_id: Option<String>,
    pub extra_options: BTreeMap<String, String>,
}
```

Field contract:

- `engine: InstallerEngine`
  - Required.
  - Requested installer engine.
  - Values: `InstallerEngine::V1 | InstallerEngine::V2`.
- `mode: InstallMode`
  - Required.
  - Install execution mode.
  - Values: `InstallMode::Interactive | InstallMode::NonInteractive`.
- `pack: String`
  - Required.
  - Canonical pack id, matching directory name under `packs/<name>/`.
- `profile: Option<String>`
  - Optional at parse time.
  - Canonical profile id. May be inferred from pack defaults in interactive or `--yes` flows.
- `method: Option<DeployMethodId>`
  - Optional at parse time.
  - Deployment method id. May be inferred from pack/profile defaults.
- `region: Option<String>`
  - Optional.
  - AWS region, e.g. `us-east-1`.
- `stack_name: Option<String>`
  - Optional.
  - Logical deployment name for methods that create named resources such as CloudFormation stacks.
- `auto_yes: bool`
  - Required.
  - `true` when defaults/prompts should be auto-accepted where safe.
- `json_output: bool`
  - Required.
  - `true` when machine-readable output is requested.
- `resume_session_id: Option<String>`
  - Optional.
  - Existing session id to resume.
- `extra_options: BTreeMap<String, String>`
  - Required, possibly empty.
  - Adapter-specific or future-compatible normalized key/value options.

Supporting enums:

```rust
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum InstallerEngine {
    V1,
    V2,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum InstallMode {
    Interactive,
    NonInteractive,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum DeployMethodId {
    Cfn,
    Terraform,
}
```

Validation rules:

- `pack` must resolve to an existing `packs/<pack>/manifest.yaml`.
- `profile`, when present, must exist in the selected pack's `allowed_profiles`.
- `method`, when present, must exist in the selected pack's `supported_methods`.
- `mode == NonInteractive` requires all fields marked as required-by-plan after default inference to be resolvable without prompting.
- `stack_name` is required if the selected method manifest marks `requires_stack_name = true`.
- Unknown CLI flags must either normalize into `extra_options` or fail before planning.

## InstallPlan Schema

`InstallPlan` is the fully resolved execution contract produced by planning and consumed by adapters.

```rust
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InstallPlan {
    pub request: InstallRequest,
    pub resolved_pack: PackManifest,
    pub resolved_profile: ProfileManifest,
    pub resolved_method: MethodManifest,
    pub resolved_region: String,
    pub resolved_stack_name: Option<String>,
    pub prerequisites: Vec<PrerequisiteCheck>,
    pub deploy_steps: Vec<DeployStep>,
    pub warnings: Vec<PlanWarning>,
    pub post_install_steps: Vec<PostInstallStep>,
    pub session_persistence: SessionPersistenceSpec,
    pub adapter_options: BTreeMap<String, String>,
}
```

Field contract:

- `request: InstallRequest`
  - Required.
  - Original normalized request.
- `resolved_pack: PackManifest`
  - Required.
  - Fully loaded pack manifest.
- `resolved_profile: ProfileManifest`
  - Required.
  - Fully loaded selected profile manifest.
- `resolved_method: MethodManifest`
  - Required.
  - Fully loaded selected method manifest.
- `resolved_region: String`
  - Required.
  - Final AWS region after explicit input/default inference.
- `resolved_stack_name: Option<String>`
  - Optional.
  - Final stack name when applicable to the method.
- `prerequisites: Vec<PrerequisiteCheck>`
  - Required, possibly empty.
  - Ordered preflight checks to satisfy before apply.
- `deploy_steps: Vec<DeployStep>`
  - Required, non-empty for `install`.
  - Ordered execution steps shown in CLI/TUI and persisted in session state.
- `warnings: Vec<PlanWarning>`
  - Required, possibly empty.
  - Non-fatal issues surfaced during review.
- `post_install_steps: Vec<PostInstallStep>`
  - Required, possibly empty.
  - Ordered actions or guidance after successful deployment.
- `session_persistence: SessionPersistenceSpec`
  - Required.
  - JSON session persistence policy for resume/status support.
- `adapter_options: BTreeMap<String, String>`
  - Required, possibly empty.
  - Method-specific resolved values passed to the adapter.

Supporting types:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PrerequisiteCheck {
    pub id: String,
    pub display_name: String,
    pub kind: PrerequisiteKind,
    pub required: bool,
    pub remediation: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PrerequisiteKind {
    OsSupported,
    ArchSupported,
    AwsCliPresent,
    AwsCredentialsValid,
    AwsCallerIdentityResolvable,
    NetworkReachable,
    BinaryDownloadable,
    MethodToolingPresent,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeployStep {
    pub id: String,
    pub phase: InstallPhase,
    pub display_name: String,
    pub action: DeployAction,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum InstallPhase {
    ValidateEnvironment,
    DiscoverAwsContext,
    ResolveMetadata,
    PrepareDeployment,
    PlanDeployment,
    ApplyDeployment,
    WaitForResources,
    Finalize,
    PostInstall,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DeployAction {
    RunCommand { program: String, args: Vec<String> },
    CreateStack,
    UpdateStack,
    DestroyStack,
    WaitForStack,
    VerifyInstanceHealth,
    EmitInstructions,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlanWarning {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PostInstallStep {
    pub id: String,
    pub display_name: String,
    pub instruction: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionPersistenceSpec {
    pub format: SessionFormat,
    pub path_hint: String,
    pub persist_phases: Vec<InstallPhase>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SessionFormat {
    Json,
}
```

Validation rules:

- `resolved_profile.id` must be allowed by `resolved_pack.allowed_profiles`.
- `resolved_method.id` must be present in `resolved_pack.supported_methods`.
- `session_persistence.format` must be `Json`.
- Every `deploy_steps[*].id` must be unique and stable across resume boundaries.

## Pack Manifest YAML Schema

Location:

- `packs/<name>/manifest.yaml`

Rust schema:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PackManifest {
    pub schema_version: u32,
    pub id: String,
    pub display_name: String,
    pub description: Option<String>,
    pub experimental: bool,
    pub allowed_profiles: Vec<String>,
    pub supported_methods: Vec<DeployMethodId>,
    pub default_profile: Option<String>,
    pub default_method: Option<DeployMethodId>,
    pub default_region: Option<String>,
    pub post_install: Vec<PostInstallActionId>,
    pub required_env: Vec<String>,
    pub extra_options_schema: BTreeMap<String, PackOptionSpec>,
}
```

Supporting types:

```rust
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PostInstallActionId {
    SsmSession,
    Pairing,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PackOptionSpec {
    pub value_type: OptionValueType,
    pub required: bool,
    pub default_value: Option<String>,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OptionValueType {
    String,
    Integer,
    Boolean,
}
```

Field contract:

- `schema_version: u32`
  - Required.
  - Manifest schema version for migrations.
- `id: String`
  - Required.
  - Canonical pack id. Must equal `<name>` in `packs/<name>/`.
- `display_name: String`
  - Required.
- `description: Option<String>`
  - Optional.
- `experimental: bool`
  - Required.
- `allowed_profiles: Vec<String>`
  - Required, non-empty.
  - Profile ids that may be used with this pack.
- `supported_methods: Vec<DeployMethodId>`
  - Required, non-empty.
- `default_profile: Option<String>`
  - Optional.
  - Must be present in `allowed_profiles` when set.
- `default_method: Option<DeployMethodId>`
  - Optional.
  - Must be present in `supported_methods` when set.
- `default_region: Option<String>`
  - Optional.
- `post_install: Vec<PostInstallActionId>`
  - Required, possibly empty.
- `required_env: Vec<String>`
  - Required, possibly empty.
  - Environment variables or external settings needed before deploy.
- `extra_options_schema: BTreeMap<String, PackOptionSpec>`
  - Required, possibly empty.
  - Pack-specific option definitions that populate `InstallRequest.extra_options`.

Example YAML:

```yaml
schema_version: 1
id: openclaw
display_name: OpenClaw
description: Default Loki Agent workstation deployment
experimental: false
allowed_profiles:
  - builder
  - account_assistant
supported_methods:
  - cfn
  - terraform
default_profile: builder
default_method: cfn
default_region: us-east-1
post_install:
  - ssm_session
  - pairing
required_env: []
extra_options_schema: {}
```

## Profile Manifest Schema

Recommended location:

- `profiles/<profile>.yaml`

Rust schema:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProfileManifest {
    pub schema_version: u32,
    pub id: String,
    pub display_name: String,
    pub description: Option<String>,
    pub supported_packs: Vec<String>,
    pub default_method: Option<DeployMethodId>,
    pub default_region: Option<String>,
    pub config: BTreeMap<String, String>,
    pub tags: BTreeMap<String, String>,
}
```

Field contract:

- `schema_version: u32`
  - Required.
- `id: String`
  - Required.
  - Canonical profile id.
- `display_name: String`
  - Required.
- `description: Option<String>`
  - Optional.
- `supported_packs: Vec<String>`
  - Required, non-empty.
  - Pack ids this profile supports. Must include the selected pack during planning.
- `default_method: Option<DeployMethodId>`
  - Optional.
  - Used only if also supported by the selected pack.
- `default_region: Option<String>`
  - Optional.
- `config: BTreeMap<String, String>`
  - Required, possibly empty.
  - Static profile-level configuration merged into adapter inputs.
- `tags: BTreeMap<String, String>`
  - Required, possibly empty.
  - Resource tags or metadata emitted into deployment plans.

## Method Manifest Schema

Recommended location:

- `methods/<method>.yaml`

Rust schema:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MethodManifest {
    pub schema_version: u32,
    pub id: DeployMethodId,
    pub display_name: String,
    pub description: Option<String>,
    pub requires_stack_name: bool,
    pub requires_region: bool,
    pub required_tools: Vec<String>,
    pub supports_resume: bool,
    pub supports_uninstall: bool,
    pub input_schema: BTreeMap<String, MethodOptionSpec>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MethodOptionSpec {
    pub value_type: OptionValueType,
    pub required: bool,
    pub default_value: Option<String>,
    pub description: Option<String>,
}
```

Field contract:

- `schema_version: u32`
  - Required.
- `id: DeployMethodId`
  - Required.
- `display_name: String`
  - Required.
- `description: Option<String>`
  - Optional.
- `requires_stack_name: bool`
  - Required.
- `requires_region: bool`
  - Required.
- `required_tools: Vec<String>`
  - Required, possibly empty.
  - Executables expected on the host, e.g. `aws`, `terraform`.
- `supports_resume: bool`
  - Required.
- `supports_uninstall: bool`
  - Required.
- `input_schema: BTreeMap<String, MethodOptionSpec>`
  - Required, possibly empty.
  - Method-specific options merged into `InstallRequest.extra_options` and `InstallPlan.adapter_options`.

## DeployAdapter Trait Interface

`DeployAdapter` is the stable execution boundary between the installer core and a deployment method implementation. It must be TUI-agnostic and usable from both CLI and interactive flows.

```rust
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use std::collections::BTreeMap;

#[async_trait]
pub trait DeployAdapter: Send + Sync {
    fn method_id(&self) -> DeployMethodId;

    fn validate_request(
        &self,
        request: &InstallRequest,
        pack: &PackManifest,
        profile: Option<&ProfileManifest>,
        method: &MethodManifest,
    ) -> Result<(), AdapterValidationError>;

    async fn build_plan(
        &self,
        request: &InstallRequest,
        pack: &PackManifest,
        profile: &ProfileManifest,
        method: &MethodManifest,
    ) -> Result<AdapterPlan, AdapterError>;

    async fn apply(
        &self,
        plan: &InstallPlan,
        session: &mut InstallSession,
        event_sink: &mut dyn InstallEventSink,
    ) -> Result<ApplyResult, AdapterError>;

    async fn resume(
        &self,
        session: &mut InstallSession,
        event_sink: &mut dyn InstallEventSink,
    ) -> Result<ApplyResult, AdapterError>;

    async fn uninstall(
        &self,
        session: &InstallSession,
        event_sink: &mut dyn InstallEventSink,
    ) -> Result<UninstallResult, AdapterError>;

    async fn status(
        &self,
        session: &InstallSession,
    ) -> Result<DeployStatus, AdapterError>;
}
```

Supporting types:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterPlan {
    pub prerequisites: Vec<PrerequisiteCheck>,
    pub deploy_steps: Vec<DeployStep>,
    pub adapter_options: BTreeMap<String, String>,
    pub warnings: Vec<PlanWarning>,
    pub post_install_steps: Vec<PostInstallStep>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InstallSession {
    pub session_id: String,
    pub installer_version: String,
    pub engine: InstallerEngine,
    pub mode: InstallMode,
    pub request: InstallRequest,
    pub plan: Option<InstallPlan>,
    pub phase: InstallPhase,
    pub started_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub artifacts: BTreeMap<String, String>,
    pub status_summary: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ApplyResult {
    pub final_phase: InstallPhase,
    pub artifacts: BTreeMap<String, String>,
    pub post_install_steps: Vec<PostInstallStep>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UninstallResult {
    pub removed_artifacts: BTreeMap<String, String>,
    pub warnings: Vec<PlanWarning>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeployStatus {
    pub deployed: bool,
    pub pack: String,
    pub profile: String,
    pub method: DeployMethodId,
    pub region: Option<String>,
    pub stack_name: Option<String>,
    pub stack_status: Option<String>,
    pub instance_health: Option<String>,
    pub last_updated_at: DateTime<Utc>,
}

#[derive(Debug, thiserror::Error)]
pub enum AdapterValidationError {
    #[error("missing required field: {0}")]
    MissingField(&'static str),
    #[error("unsupported value for {field}: {value}")]
    UnsupportedValue { field: &'static str, value: String },
    #[error("invalid option: {0}")]
    InvalidOption(String),
}

#[derive(Debug, thiserror::Error)]
pub enum AdapterError {
    #[error("preflight failed: {0}")]
    Preflight(String),
    #[error("command failed: {program}")]
    CommandFailed { program: String, stderr: String },
    #[error("session is not resumable")]
    NotResumable,
    #[error("deployment state missing: {0}")]
    MissingArtifact(&'static str),
    #[error("{0}")]
    Other(String),
}

#[async_trait]
pub trait InstallEventSink: Send {
    async fn emit(&mut self, event: InstallEvent);
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum InstallEvent {
    PhaseStarted { phase: InstallPhase, message: String },
    StepStarted { step_id: String, message: String },
    StepFinished { step_id: String, message: String },
    Warning { code: String, message: String },
    ArtifactRecorded { key: String, value: String },
    LogLine { message: String },
}
```

Trait requirements:

- `validate_request` must be pure validation and must not mutate state or call external systems.
- `build_plan` may probe the environment needed for planning but must not create remote resources.
- `apply` must update `session.phase` and emit `InstallEvent`s at stable boundaries.
- `resume` must continue from persisted JSON session state without re-running completed idempotent phases unnecessarily.
- `uninstall` must tolerate already-removed resources where safe.
- `status` backs the `loki-installer status` command and must read from persisted session data plus provider state as needed.

## Minimum Compatibility Rules

- V1 and V2 must normalize user input into the same `InstallRequest`.
- V1 and V2 must resolve against the same pack/profile/method manifests.
- Any new pack, profile, or method must be representable without changing the public `InstallRequest` schema.
- Session files must be JSON and sufficient for `resume` and `status`.
