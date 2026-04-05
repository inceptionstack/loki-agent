//! TUI runtime loop and rendering.

use crate::core::{InstallEvent, InstallEventSink, Planner};
use crate::tui::app::{AppLifecycle, AppState, ScreenId, screen_title};
use crate::tui::events::InstallerEvent;
use crate::tui::screens;
use crate::tui::update::{AppAction, update};
use async_trait::async_trait;
use color_eyre::Result;
use crossterm::{
    event::{Event, EventStream},
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use futures::StreamExt;
use ratatui::{
    Terminal,
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Flex, Layout, Rect},
    style::{Modifier, Style},
    widgets::{Block, Borders, Clear, Paragraph},
};
use std::collections::VecDeque;
use std::io::{self, Stdout};
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};

pub async fn run(planner: Planner) -> Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;
    let mut state = AppState::default();
    let mut events = EventStream::new();
    let (deploy_tx, mut deploy_rx) = unbounded_channel();

    let mut pending = VecDeque::from(update(&mut state, InstallerEvent::AppStarted));
    while state.lifecycle == AppLifecycle::Running {
        run_actions(
            &planner,
            &deploy_tx,
            &mut state,
            &mut pending,
            &mut terminal,
        )
        .await?;
        tokio::select! {
            event = events.next() => {
                match event {
                    Some(Ok(Event::Key(key))) => {
                        pending.extend(update(&mut state, InstallerEvent::KeyPressed(key)));
                    }
                    Some(Ok(Event::Resize(width, height))) => {
                        pending.extend(update(&mut state, InstallerEvent::Resize { width, height }));
                    }
                    Some(Ok(_)) => {}
                    Some(Err(err)) => return Err(err.into()),
                    None => {
                        state.lifecycle = AppLifecycle::Exiting;
                    }
                }
            }
            deploy_event = deploy_rx.recv() => {
                if let Some(event) = deploy_event {
                    pending.extend(update(&mut state, event));
                }
            }
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;
    Ok(())
}

async fn run_actions(
    planner: &Planner,
    deploy_tx: &UnboundedSender<InstallerEvent>,
    state: &mut AppState,
    pending: &mut VecDeque<AppAction>,
    terminal: &mut Terminal<CrosstermBackend<Stdout>>,
) -> Result<()> {
    while let Some(action) = pending.pop_front() {
        match action {
            AppAction::Render => render(terminal, state)?,
            AppAction::LoadPacks => {
                let packs = planner.repo().load_all_packs().map_err(|e| e.to_string());
                pending.extend(update(state, InstallerEvent::PacksLoaded(packs)));
            }
            AppAction::LoadProfiles { pack_id } => {
                let result = planner
                    .repo()
                    .load_pack(&pack_id)
                    .and_then(|pack| planner.repo().load_profiles_for_pack(&pack))
                    .map_err(|e| e.to_string());
                pending.extend(update(state, InstallerEvent::ProfilesLoaded(result)));
            }
            AppAction::LoadMethods { pack_id } => {
                let result = planner
                    .repo()
                    .load_pack(&pack_id)
                    .and_then(|pack| planner.repo().load_methods_for_pack(&pack))
                    .map_err(|e| e.to_string());
                pending.extend(update(state, InstallerEvent::MethodsLoaded(result)));
            }
            AppAction::RunDoctor => {
                let report = planner
                    .run_doctor(
                        None,
                        crate::core::RepoAvailabilityCheck {
                            passed: true,
                            message: format!(
                                "repo available at {}",
                                planner.repo().root().display()
                            ),
                        },
                    )
                    .map_err(|e| e.to_string());
                pending.extend(update(state, InstallerEvent::DoctorCompleted(report)));
            }
            AppAction::BuildPlan => {
                let result = match state.request_draft.to_request() {
                    Some(request) => planner.build_plan(request).await.map_err(|e| e.to_string()),
                    None => Err("pack selection is incomplete".into()),
                };
                pending.extend(update(state, InstallerEvent::PlanBuilt(Box::new(result))));
            }
            AppAction::StartDeploy => {
                if let Some(plan) = state.plan.clone() {
                    state.deployment.current_phase = None;
                    state.deployment.logs.clear();
                    render(terminal, state)?;

                    let planner = planner.clone();
                    let task_tx = deploy_tx.clone();
                    match planner.create_install_session(plan) {
                        Ok(session) => {
                            state.session = Some(session.clone());
                            tokio::spawn(async move {
                                let mut session = session;
                                let mut sink = TuiEventSink::new(task_tx.clone());
                                if let Err(err) = sink
                                    .emit_line(
                                        format!("Created install session {}", session.session_id),
                                        None,
                                    )
                                    .await
                                {
                                    let _ = task_tx.send(InstallerEvent::DeployFailed(err));
                                    return;
                                }
                                match planner
                                    .execute_install_with_sink(&mut session, &mut sink)
                                    .await
                                {
                                    Ok(()) => {
                                        let _ = task_tx.send(InstallerEvent::DeployFinished(
                                            Box::new(session),
                                        ));
                                    }
                                    Err(err) => {
                                        let _ = task_tx
                                            .send(InstallerEvent::DeployFailed(err.to_string()));
                                    }
                                }
                            });
                        }
                        Err(err) => pending
                            .extend(update(state, InstallerEvent::DeployFailed(err.to_string()))),
                    }
                }
            }
            AppAction::Exit => {
                state.lifecycle = AppLifecycle::Exiting;
                break;
            }
        }
    }
    Ok(())
}

struct TuiEventSink {
    tx: UnboundedSender<InstallerEvent>,
}

impl TuiEventSink {
    fn new(tx: UnboundedSender<InstallerEvent>) -> Self {
        Self { tx }
    }

    async fn emit_line(
        &mut self,
        message: String,
        phase: Option<crate::core::InstallPhase>,
    ) -> Result<(), String> {
        self.tx
            .send(InstallerEvent::DeployLogLine { message, phase })
            .map_err(|err| err.to_string())
    }
}

#[async_trait]
impl InstallEventSink for TuiEventSink {
    async fn emit(&mut self, event: InstallEvent) {
        let result = match event {
            InstallEvent::PhaseStarted { phase, message } => {
                self.emit_line(message, Some(phase)).await
            }
            InstallEvent::StepStarted {
                step_id,
                display_name,
            } => {
                self.emit_line(format!("Starting {display_name} ({step_id})"), None)
                    .await
            }
            InstallEvent::StepFinished { step_id, message } => {
                let summary = if message.is_empty() {
                    format!("Finished {step_id}")
                } else {
                    format!("Finished {step_id}: {message}")
                };
                self.emit_line(summary, None).await
            }
            InstallEvent::Warning { code, message } => {
                self.emit_line(format!("Warning [{code}]: {message}"), None)
                    .await
            }
            InstallEvent::ArtifactRecorded { key, value } => {
                self.emit_line(format!("Recorded artifact {key}={value}"), None)
                    .await
            }
            InstallEvent::LogLine { message } => self.emit_line(message, None).await,
            InstallEvent::StackEvent {
                resource,
                status,
                resource_type,
            } => {
                self.emit_line(format!("{resource_type} {resource}: {status}"), None)
                    .await
            }
        };

        if let Err(err) = result {
            let _ = self.tx.send(InstallerEvent::DeployFailed(err));
        }
    }
}

fn render(terminal: &mut Terminal<CrosstermBackend<Stdout>>, state: &AppState) -> Result<()> {
    terminal.draw(|frame| {
        let areas = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(1), Constraint::Length(1)])
            .split(frame.area());
        let body = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Length(22), Constraint::Min(20)])
            .split(areas[0]);

        let checklist = [
            ScreenId::Welcome,
            ScreenId::DoctorPreflight,
            ScreenId::PackSelection,
            ScreenId::ProfileSelection,
            ScreenId::MethodSelection,
            ScreenId::Review,
            ScreenId::DeployProgress,
            ScreenId::PostInstall,
        ]
        .iter()
        .map(|screen| {
            let marker = if *screen == state.screen { ">" } else { " " };
            format!("{marker} {}", screen_title(*screen))
        })
        .collect::<Vec<_>>()
        .join("\n");

        frame.render_widget(
            Paragraph::new(checklist)
                .block(Block::default().title("Checklist").borders(Borders::ALL)),
            body[0],
        );

        let content = match state.screen {
            ScreenId::Welcome => screens::welcome::content(),
            ScreenId::DoctorPreflight => screens::preflight::content(state),
            ScreenId::PackSelection => screens::pack_select::content(state),
            ScreenId::ProfileSelection => screens::profile_select::content(state),
            ScreenId::MethodSelection => screens::method_select::content(state),
            ScreenId::Review => screens::review::content(state),
            ScreenId::DeployProgress => screens::deploy::content(state),
            ScreenId::PostInstall => screens::post_install::content(state),
        };

        frame.render_widget(
            Paragraph::new(content).block(
                Block::default()
                    .title(screen_title(state.screen))
                    .borders(Borders::ALL),
            ),
            body[1],
        );

        frame.render_widget(
            Paragraph::new(footer_text(state)).style(Style::default().add_modifier(Modifier::BOLD)),
            areas[1],
        );

        if state.ui.help_visible {
            let help_area = centered_rect(66, 14, frame.area());
            frame.render_widget(Clear, help_area);
            frame.render_widget(
                Paragraph::new(help_text())
                    .block(Block::default().title("Help").borders(Borders::ALL)),
                help_area,
            );
        }
    })?;
    Ok(())
}

fn footer_text(state: &AppState) -> String {
    if state.ui.help_visible {
        return "Help open | Esc close | q quit".into();
    }

    state
        .errors
        .last()
        .map(|error| format!("Error: {} | ? help | q quit | b/h back", error.message))
        .unwrap_or_else(|| {
            "Hints: Enter/Tab/l next | Space select | b/h back | arrows move | ? help | q quit"
                .into()
        })
}

fn help_text() -> &'static str {
    "Enter, Tab, Right, l: next\n\
Space: select current item\n\
Left, BackTab, b, h: back\n\
Up/Down, j/k: move\n\
r: retry current load or action when available\n\
?: toggle help\n\
Esc: close help\n\
q or Ctrl+C: quit"
}

fn centered_rect(width: u16, height: u16, area: Rect) -> Rect {
    let [vertical] = Layout::vertical([Constraint::Length(height)])
        .flex(Flex::Center)
        .areas(area);
    let [horizontal] = Layout::horizontal([Constraint::Length(width)])
        .flex(Flex::Center)
        .areas(vertical);
    horizontal
}
