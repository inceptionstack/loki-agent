//! Pure TUI state transition logic.

use crate::tui::app::{AppLifecycle, AppState, ScreenId, UserFacingError};
use crate::tui::events::InstallerEvent;
use crossterm::event::{KeyCode, KeyModifiers};

#[derive(Debug)]
pub enum AppAction {
    Render,
    LoadPacks,
    LoadProfiles { pack_id: String },
    LoadMethods { pack_id: String },
    RunDoctor,
    BuildPlan,
    StartDeploy,
    Exit,
}

pub fn update(state: &mut AppState, event: InstallerEvent) -> Vec<AppAction> {
    match event {
        InstallerEvent::AppStarted => vec![AppAction::Render],
        InstallerEvent::KeyPressed(key) => match key.code {
            KeyCode::Char('q') => {
                state.lifecycle = AppLifecycle::Exiting;
                vec![AppAction::Exit]
            }
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                state.lifecycle = AppLifecycle::Exiting;
                vec![AppAction::Exit]
            }
            KeyCode::Enter => advance(state),
            KeyCode::Char('b') | KeyCode::Left => go_back(state),
            KeyCode::Down | KeyCode::Char('j') => {
                move_cursor(state, 1);
                vec![AppAction::Render]
            }
            KeyCode::Up | KeyCode::Char('k') => {
                move_cursor(state, -1);
                vec![AppAction::Render]
            }
            _ => vec![AppAction::Render],
        },
        InstallerEvent::PacksLoaded(result) => {
            if let Ok(packs) = result {
                state.packs = packs;
                if let Some(pack) = state.packs.get(state.request_draft.pack_cursor) {
                    state.request_draft.pack_id = Some(pack.id.clone());
                }
                state.screen = ScreenId::PackSelection;
            }
            vec![AppAction::Render]
        }
        InstallerEvent::ProfilesLoaded(result) => {
            if let Ok(profiles) = result {
                state.profiles = profiles;
                if let Some(profile) = state.profiles.get(state.request_draft.profile_cursor) {
                    state.request_draft.profile_id = Some(profile.id.clone());
                }
                state.screen = ScreenId::ProfileSelection;
            }
            vec![AppAction::Render]
        }
        InstallerEvent::MethodsLoaded(result) => {
            if let Ok(methods) = result {
                state.methods = methods;
                if let Some(method) = state.methods.get(state.request_draft.method_cursor) {
                    state.request_draft.method_id = Some(method.id);
                }
                state.screen = ScreenId::MethodSelection;
            }
            vec![AppAction::Render]
        }
        InstallerEvent::DoctorCompleted(result) => {
            match result {
                Ok(report) => {
                    state.doctor.report = Some(report);
                    state.screen = ScreenId::DoctorPreflight;
                }
                Err(err) => state.errors.push(UserFacingError { message: err }),
            }
            vec![AppAction::Render]
        }
        InstallerEvent::PlanBuilt(result) => {
            match result {
                Ok(plan) => {
                    state.request_draft.region = Some(plan.resolved_region.clone());
                    state.request_draft.stack_name = plan.resolved_stack_name.clone();
                    state.plan = Some(plan);
                    state.screen = ScreenId::Review;
                }
                Err(err) => state.errors.push(UserFacingError { message: err }),
            }
            vec![AppAction::Render]
        }
        InstallerEvent::DeployFinished(result) => {
            match result {
                Ok(_) => state.screen = ScreenId::PostInstall,
                Err(err) => state.errors.push(UserFacingError { message: err }),
            }
            vec![AppAction::Render]
        }
        InstallerEvent::Resize { width, height } => {
            state.ui.width = width;
            state.ui.height = height;
            vec![AppAction::Render]
        }
    }
}

fn advance(state: &mut AppState) -> Vec<AppAction> {
    match state.screen {
        ScreenId::Welcome => vec![AppAction::RunDoctor],
        ScreenId::DoctorPreflight => vec![AppAction::LoadPacks],
        ScreenId::PackSelection => {
            if let Some(pack) = state.packs.get(state.request_draft.pack_cursor) {
                state.request_draft.pack_id = Some(pack.id.clone());
                state.request_draft.profile_id = pack.default_profile.clone();
                state.request_draft.method_id = pack.default_method;
                vec![AppAction::LoadProfiles {
                    pack_id: pack.id.clone(),
                }]
            } else {
                vec![AppAction::Render]
            }
        }
        ScreenId::ProfileSelection => {
            if let Some(profile) = state.profiles.get(state.request_draft.profile_cursor) {
                state.request_draft.profile_id = Some(profile.id.clone());
            }
            if let Some(pack_id) = &state.request_draft.pack_id {
                vec![AppAction::LoadMethods {
                    pack_id: pack_id.clone(),
                }]
            } else {
                vec![AppAction::Render]
            }
        }
        ScreenId::MethodSelection => {
            if let Some(method) = state.methods.get(state.request_draft.method_cursor) {
                state.request_draft.method_id = Some(method.id);
            }
            vec![AppAction::BuildPlan]
        }
        ScreenId::Review => {
            state.screen = ScreenId::DeployProgress;
            vec![AppAction::StartDeploy]
        }
        ScreenId::PostInstall => vec![AppAction::Exit],
        ScreenId::DeployProgress => vec![AppAction::Render],
    }
}

fn go_back(state: &mut AppState) -> Vec<AppAction> {
    state.screen = match state.screen {
        ScreenId::Welcome => ScreenId::Welcome,
        ScreenId::DoctorPreflight => ScreenId::Welcome,
        ScreenId::PackSelection => ScreenId::DoctorPreflight,
        ScreenId::ProfileSelection => ScreenId::PackSelection,
        ScreenId::MethodSelection => ScreenId::ProfileSelection,
        ScreenId::Review => ScreenId::MethodSelection,
        ScreenId::DeployProgress => ScreenId::DeployProgress,
        ScreenId::PostInstall => ScreenId::DeployProgress,
    };
    vec![AppAction::Render]
}

fn move_cursor(state: &mut AppState, delta: isize) {
    fn advance_index(current: usize, len: usize, delta: isize) -> usize {
        if len == 0 {
            return 0;
        }
        if delta.is_negative() {
            current.saturating_sub(delta.unsigned_abs())
        } else {
            (current + delta as usize).min(len.saturating_sub(1))
        }
    }

    match state.screen {
        ScreenId::PackSelection => {
            state.request_draft.pack_cursor =
                advance_index(state.request_draft.pack_cursor, state.packs.len(), delta);
        }
        ScreenId::ProfileSelection => {
            state.request_draft.profile_cursor = advance_index(
                state.request_draft.profile_cursor,
                state.profiles.len(),
                delta,
            );
        }
        ScreenId::MethodSelection => {
            state.request_draft.method_cursor = advance_index(
                state.request_draft.method_cursor,
                state.methods.len(),
                delta,
            );
        }
        _ => {}
    }
}
