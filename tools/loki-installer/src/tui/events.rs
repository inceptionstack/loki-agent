//! Internal TUI event messages.

use crate::core::{ApplyResult, InstallPlan, MethodManifest, PackManifest, ProfileManifest};
use crossterm::event::KeyEvent;

#[derive(Debug)]
pub enum InstallerEvent {
    AppStarted,
    KeyPressed(KeyEvent),
    Resize { width: u16, height: u16 },
    PacksLoaded(Result<Vec<PackManifest>, String>),
    ProfilesLoaded(Result<Vec<ProfileManifest>, String>),
    MethodsLoaded(Result<Vec<MethodManifest>, String>),
    DoctorCompleted(Result<crate::core::DoctorReport, String>),
    PlanBuilt(Result<InstallPlan, String>),
    DeployFinished(Result<ApplyResult, String>),
}
