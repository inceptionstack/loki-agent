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
        InstallerEvent::KeyPressed(key) => {
            if state.ui.help_visible {
                return match key.code {
                    KeyCode::Esc | KeyCode::Char('?') => {
                        state.ui.help_visible = false;
                        vec![AppAction::Render]
                    }
                    KeyCode::Char('q') => {
                        state.lifecycle = AppLifecycle::Exiting;
                        vec![AppAction::Exit]
                    }
                    KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        state.lifecycle = AppLifecycle::Exiting;
                        vec![AppAction::Exit]
                    }
                    _ => vec![AppAction::Render],
                };
            }

            match key.code {
                KeyCode::Char('q') => {
                    state.lifecycle = AppLifecycle::Exiting;
                    vec![AppAction::Exit]
                }
                KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    state.lifecycle = AppLifecycle::Exiting;
                    vec![AppAction::Exit]
                }
                KeyCode::Char('?') => {
                    state.ui.help_visible = true;
                    vec![AppAction::Render]
                }
                KeyCode::Esc => vec![AppAction::Render],
                KeyCode::Enter | KeyCode::Tab | KeyCode::Right | KeyCode::Char('l') => {
                    advance(state)
                }
                KeyCode::BackTab | KeyCode::Char('b') | KeyCode::Char('h') | KeyCode::Left => {
                    go_back(state)
                }
                KeyCode::Char(' ') => select_current(state),
                KeyCode::Char('r') => retry(state),
                KeyCode::Down | KeyCode::Char('j') => {
                    move_cursor(state, 1);
                    vec![AppAction::Render]
                }
                KeyCode::Up | KeyCode::Char('k') => {
                    move_cursor(state, -1);
                    vec![AppAction::Render]
                }
                _ => vec![AppAction::Render],
            }
        }
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

fn select_current(state: &mut AppState) -> Vec<AppAction> {
    match state.screen {
        ScreenId::PackSelection | ScreenId::ProfileSelection | ScreenId::MethodSelection => {
            advance(state)
        }
        _ => vec![AppAction::Render],
    }
}

fn retry(state: &mut AppState) -> Vec<AppAction> {
    match state.screen {
        ScreenId::Welcome | ScreenId::DoctorPreflight => vec![AppAction::RunDoctor],
        ScreenId::PackSelection => vec![AppAction::LoadPacks],
        ScreenId::ProfileSelection => state
            .request_draft
            .pack_id
            .clone()
            .map(|pack_id| vec![AppAction::LoadProfiles { pack_id }])
            .unwrap_or_else(|| vec![AppAction::Render]),
        ScreenId::MethodSelection => state
            .request_draft
            .pack_id
            .clone()
            .map(|pack_id| vec![AppAction::LoadMethods { pack_id }])
            .unwrap_or_else(|| vec![AppAction::Render]),
        ScreenId::Review => vec![AppAction::BuildPlan],
        ScreenId::DeployProgress => {
            if state.plan.is_some() {
                vec![AppAction::StartDeploy]
            } else {
                vec![AppAction::Render]
            }
        }
        ScreenId::PostInstall => vec![AppAction::Render],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{DeployMethodId, MethodManifest, PackManifest, ProfileManifest};
    use crossterm::event::{KeyEvent, KeyEventKind, KeyEventState};

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent {
            code,
            modifiers: KeyModifiers::NONE,
            kind: KeyEventKind::Press,
            state: KeyEventState::NONE,
        }
    }

    #[test]
    fn question_mark_toggles_help_and_escape_closes_it() {
        let mut state = AppState::default();

        let actions = update(
            &mut state,
            InstallerEvent::KeyPressed(key(KeyCode::Char('?'))),
        );
        assert!(state.ui.help_visible);
        assert!(matches!(actions.as_slice(), [AppAction::Render]));

        let actions = update(&mut state, InstallerEvent::KeyPressed(key(KeyCode::Esc)));
        assert!(!state.ui.help_visible);
        assert!(matches!(actions.as_slice(), [AppAction::Render]));
    }

    #[test]
    fn vim_and_tab_aliases_follow_existing_navigation() {
        let mut state = AppState::default();
        state.screen = ScreenId::PackSelection;
        state.packs = vec![PackManifest {
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
            extra_options_schema: Default::default(),
        }];

        let actions = update(&mut state, InstallerEvent::KeyPressed(key(KeyCode::Tab)));
        assert!(matches!(
            actions.as_slice(),
            [AppAction::LoadProfiles { pack_id }] if pack_id == "openclaw"
        ));

        state.screen = ScreenId::ProfileSelection;
        let actions = update(
            &mut state,
            InstallerEvent::KeyPressed(key(KeyCode::Char('h'))),
        );
        assert_eq!(state.screen, ScreenId::PackSelection);
        assert!(matches!(actions.as_slice(), [AppAction::Render]));
    }

    #[test]
    fn retry_replays_the_current_screen_action() {
        let mut state = AppState::default();
        state.screen = ScreenId::MethodSelection;
        state.request_draft.pack_id = Some("openclaw".into());
        state.profiles = vec![ProfileManifest {
            schema_version: 1,
            id: "builder".into(),
            display_name: "Builder".into(),
            description: None,
            supported_packs: vec!["openclaw".into()],
            default_method: Some(DeployMethodId::Cfn),
            default_region: Some("us-east-1".into()),
            config: Default::default(),
            tags: Default::default(),
        }];
        state.methods = vec![MethodManifest {
            schema_version: 1,
            id: DeployMethodId::Cfn,
            display_name: "CloudFormation".into(),
            description: None,
            requires_stack_name: true,
            requires_region: true,
            required_tools: vec!["aws".into()],
            supports_resume: true,
            supports_uninstall: true,
            input_schema: Default::default(),
        }];

        let actions = update(
            &mut state,
            InstallerEvent::KeyPressed(key(KeyCode::Char('r'))),
        );
        assert!(matches!(
            actions.as_slice(),
            [AppAction::LoadMethods { pack_id }] if pack_id == "openclaw"
        ));
    }
}
