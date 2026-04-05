//! TUI application state and screen definitions.

use crate::core::{
    DoctorReport, InstallMode, InstallPlan, InstallRequest, InstallSession, InstallerEngine,
    MethodManifest, PackManifest, ProfileManifest,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenId {
    Welcome,
    DoctorPreflight,
    PackSelection,
    ProfileSelection,
    MethodSelection,
    Review,
    DeployProgress,
    PostInstall,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppLifecycle {
    Running,
    Exiting,
}

#[derive(Debug, Clone, Default)]
pub struct InstallRequestDraft {
    pub pack_id: Option<String>,
    pub profile_id: Option<String>,
    pub method_id: Option<crate::core::DeployMethodId>,
    pub region: Option<String>,
    pub stack_name: Option<String>,
    pub auto_yes: bool,
    pub pack_cursor: usize,
    pub profile_cursor: usize,
    pub method_cursor: usize,
}

impl InstallRequestDraft {
    pub fn to_request(&self) -> Option<InstallRequest> {
        Some(InstallRequest {
            engine: InstallerEngine::V2,
            mode: InstallMode::Interactive,
            pack: self.pack_id.clone()?,
            profile: self.profile_id.clone(),
            method: self.method_id,
            region: self.region.clone(),
            stack_name: self.stack_name.clone(),
            auto_yes: self.auto_yes,
            json_output: false,
            resume_session_id: None,
            extra_options: Default::default(),
        })
    }
}

#[derive(Debug, Clone, Default)]
pub struct DoctorState {
    pub report: Option<DoctorReport>,
}

#[derive(Debug, Clone, Default)]
pub struct DeploymentState {
    pub current_phase: Option<crate::core::InstallPhase>,
    pub logs: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct UiState {
    pub width: u16,
    pub height: u16,
    pub help_visible: bool,
}

#[derive(Debug, Clone)]
pub struct UserFacingError {
    pub message: String,
}

#[derive(Debug)]
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
    pub packs: Vec<PackManifest>,
    pub profiles: Vec<ProfileManifest>,
    pub methods: Vec<MethodManifest>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            screen: ScreenId::Welcome,
            lifecycle: AppLifecycle::Running,
            request_draft: InstallRequestDraft::default(),
            doctor: DoctorState::default(),
            plan: None,
            session: None,
            deployment: DeploymentState::default(),
            ui: UiState::default(),
            errors: Vec::new(),
            packs: Vec::new(),
            profiles: Vec::new(),
            methods: Vec::new(),
        }
    }
}

pub fn screen_title(screen: ScreenId) -> &'static str {
    match screen {
        ScreenId::Welcome => "Welcome",
        ScreenId::DoctorPreflight => "Doctor",
        ScreenId::PackSelection => "Pack",
        ScreenId::ProfileSelection => "Profile",
        ScreenId::MethodSelection => "Method",
        ScreenId::Review => "Review",
        ScreenId::DeployProgress => "Deploy",
        ScreenId::PostInstall => "Post-install",
    }
}
