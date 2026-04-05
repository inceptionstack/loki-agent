//! Shared installer contract types used by CLI, TUI, planner, and adapters.

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

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

impl InstallRequest {
    pub fn validate_contract(&self) -> Result<(), String> {
        if self.pack.trim().is_empty() {
            return Err("pack is required".into());
        }

        if self.mode == InstallMode::NonInteractive && !self.auto_yes {
            return Err("non-interactive requests must enable auto_yes".into());
        }

        Ok(())
    }
}

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

impl std::fmt::Display for DeployMethodId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Cfn => write!(f, "cfn"),
            Self::Terraform => write!(f, "terraform"),
        }
    }
}

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

impl InstallPlan {
    pub fn validate_contract(&self) -> Result<(), String> {
        self.request.validate_contract()?;
        self.resolved_pack.validate_contract()?;
        self.resolved_profile.validate_contract()?;
        self.resolved_method.validate_contract()?;

        if !self
            .resolved_pack
            .allowed_profiles
            .contains(&self.resolved_profile.id)
        {
            return Err(format!(
                "resolved profile {} is not allowed by pack {}",
                self.resolved_profile.id, self.resolved_pack.id
            ));
        }

        if !self
            .resolved_pack
            .supported_methods
            .contains(&self.resolved_method.id)
        {
            return Err(format!(
                "resolved method {} is not supported by pack {}",
                self.resolved_method.id, self.resolved_pack.id
            ));
        }

        if self.session_persistence.format != SessionFormat::Json {
            return Err("session persistence format must be json".into());
        }

        let mut step_ids = BTreeSet::new();
        for step in &self.deploy_steps {
            if !step_ids.insert(step.id.clone()) {
                return Err(format!("duplicate deploy step id {}", step.id));
            }
        }

        if self.deploy_steps.is_empty() {
            return Err("deploy plan must contain at least one deploy step".into());
        }

        Ok(())
    }
}

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

impl std::fmt::Display for InstallPhase {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let label = match self {
            Self::ValidateEnvironment => "validate_environment",
            Self::DiscoverAwsContext => "discover_aws_context",
            Self::ResolveMetadata => "resolve_metadata",
            Self::PrepareDeployment => "prepare_deployment",
            Self::PlanDeployment => "plan_deployment",
            Self::ApplyDeployment => "apply_deployment",
            Self::WaitForResources => "wait_for_resources",
            Self::Finalize => "finalize",
            Self::PostInstall => "post_install",
        };
        write!(f, "{label}")
    }
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

impl PackManifest {
    pub fn validate_contract(&self) -> Result<(), String> {
        if self.schema_version == 0 {
            return Err("pack schema_version must be positive".into());
        }
        if self.id.trim().is_empty() {
            return Err("pack id is required".into());
        }
        if self.allowed_profiles.is_empty() {
            return Err(format!("pack {} must allow at least one profile", self.id));
        }
        if self.supported_methods.is_empty() {
            return Err(format!("pack {} must support at least one method", self.id));
        }
        if let Some(default_profile) = &self.default_profile
            && !self.allowed_profiles.contains(default_profile)
        {
            return Err(format!(
                "pack {} default profile {} is not allowed",
                self.id, default_profile
            ));
        }
        if let Some(default_method) = self.default_method
            && !self.supported_methods.contains(&default_method)
        {
            return Err(format!(
                "pack {} default method {} is not supported",
                self.id, default_method
            ));
        }

        Ok(())
    }
}

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

impl ProfileManifest {
    pub fn validate_contract(&self) -> Result<(), String> {
        if self.schema_version == 0 {
            return Err("profile schema_version must be positive".into());
        }
        if self.id.trim().is_empty() {
            return Err("profile id is required".into());
        }
        if self.supported_packs.is_empty() {
            return Err(format!(
                "profile {} must support at least one pack",
                self.id
            ));
        }

        Ok(())
    }
}

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

impl MethodManifest {
    pub fn validate_contract(&self) -> Result<(), String> {
        if self.schema_version == 0 {
            return Err("method schema_version must be positive".into());
        }
        if self.display_name.trim().is_empty() {
            return Err(format!("method {} display_name is required", self.id));
        }

        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MethodOptionSpec {
    pub value_type: OptionValueType,
    pub required: bool,
    pub default_value: Option<String>,
    pub description: Option<String>,
}

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
    #[error("invalid option: {0}")]
    InvalidOption(String),
}

#[derive(Debug, thiserror::Error)]
pub enum AdapterError {
    #[error("session is not resumable")]
    NotResumable,
}

#[async_trait]
pub trait InstallEventSink: Send {
    async fn emit(&mut self, event: InstallEvent);
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum InstallEvent {
    PhaseStarted {
        phase: InstallPhase,
        message: String,
    },
    StepStarted {
        step_id: String,
        message: String,
    },
    StepFinished {
        step_id: String,
        message: String,
    },
    Warning {
        code: String,
        message: String,
    },
    ArtifactRecorded {
        key: String,
        value: String,
    },
    LogLine {
        message: String,
    },
}

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

    async fn status(&self, session: &InstallSession) -> Result<DeployStatus, AdapterError>;
}

#[cfg(test)]
mod tests {
    use super::{
        DeployAction, DeployMethodId, DeployStep, InstallMode, InstallPhase, InstallPlan,
        InstallRequest, InstallerEngine, MethodManifest, OptionValueType, PackManifest,
        PostInstallStep, PrerequisiteCheck, PrerequisiteKind, ProfileManifest, SessionFormat,
        SessionPersistenceSpec,
    };
    use std::collections::BTreeMap;

    fn sample_request() -> InstallRequest {
        InstallRequest {
            engine: InstallerEngine::V2,
            mode: InstallMode::NonInteractive,
            pack: "openclaw".into(),
            profile: Some("builder".into()),
            method: Some(DeployMethodId::Cfn),
            region: Some("us-east-1".into()),
            stack_name: Some("loki-openclaw".into()),
            auto_yes: true,
            json_output: false,
            resume_session_id: None,
            extra_options: BTreeMap::new(),
        }
    }

    #[test]
    fn request_validation_rejects_missing_pack() {
        let mut request = sample_request();
        request.pack.clear();
        assert!(request.validate_contract().is_err());
    }

    #[test]
    fn plan_validation_rejects_duplicate_step_ids() {
        let request = sample_request();
        let plan = InstallPlan {
            request,
            resolved_pack: PackManifest {
                schema_version: 1,
                id: "openclaw".into(),
                display_name: "OpenClaw".into(),
                description: None,
                experimental: false,
                allowed_profiles: vec!["builder".into()],
                supported_methods: vec![DeployMethodId::Cfn],
                default_profile: Some("builder".into()),
                default_method: Some(DeployMethodId::Cfn),
                default_region: Some("us-east-1".into()),
                post_install: vec![],
                required_env: vec![],
                extra_options_schema: BTreeMap::new(),
            },
            resolved_profile: ProfileManifest {
                schema_version: 1,
                id: "builder".into(),
                display_name: "Builder".into(),
                description: None,
                supported_packs: vec!["openclaw".into()],
                default_method: Some(DeployMethodId::Cfn),
                default_region: Some("us-east-1".into()),
                config: BTreeMap::new(),
                tags: BTreeMap::new(),
            },
            resolved_method: MethodManifest {
                schema_version: 1,
                id: DeployMethodId::Cfn,
                display_name: "CloudFormation".into(),
                description: None,
                requires_stack_name: true,
                requires_region: true,
                required_tools: vec!["aws".into()],
                supports_resume: true,
                supports_uninstall: true,
                input_schema: BTreeMap::from([(
                    "capabilities".into(),
                    super::MethodOptionSpec {
                        value_type: OptionValueType::String,
                        required: false,
                        default_value: None,
                        description: None,
                    },
                )]),
            },
            resolved_region: "us-east-1".into(),
            resolved_stack_name: Some("loki-openclaw".into()),
            prerequisites: vec![PrerequisiteCheck {
                id: "aws".into(),
                display_name: "AWS".into(),
                kind: PrerequisiteKind::AwsCliPresent,
                required: true,
                remediation: None,
            }],
            deploy_steps: vec![
                DeployStep {
                    id: "duplicate".into(),
                    phase: InstallPhase::ApplyDeployment,
                    display_name: "one".into(),
                    action: DeployAction::CreateStack,
                },
                DeployStep {
                    id: "duplicate".into(),
                    phase: InstallPhase::WaitForResources,
                    display_name: "two".into(),
                    action: DeployAction::WaitForStack,
                },
            ],
            warnings: vec![],
            post_install_steps: vec![PostInstallStep {
                id: "post".into(),
                display_name: "Post".into(),
                instruction: "Inspect outputs".into(),
            }],
            session_persistence: SessionPersistenceSpec {
                format: SessionFormat::Json,
                path_hint: "/tmp/session.json".into(),
                persist_phases: vec![InstallPhase::ApplyDeployment],
            },
            adapter_options: BTreeMap::new(),
        };

        assert!(plan.validate_contract().is_err());
    }
}
