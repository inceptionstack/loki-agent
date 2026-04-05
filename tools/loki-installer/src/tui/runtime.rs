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
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
    widgets::{Block, Borders, Clear, Paragraph},
};
use serde::Deserialize;
use std::collections::{BTreeMap, VecDeque};
use std::io::{self, Stdout};
use std::time::Duration;
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
use tokio::time::MissedTickBehavior;

pub async fn run(planner: Planner) -> Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;
    let mut state = AppState::default();
    let mut events = EventStream::new();
    let (deploy_tx, mut deploy_rx) = unbounded_channel();
    let mut tick = tokio::time::interval(Duration::from_millis(100));
    tick.set_missed_tick_behavior(MissedTickBehavior::Skip);

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
            _ = tick.tick() => {
                pending.extend(update(&mut state, InstallerEvent::Tick));
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
                let packs = load_tui_packs(planner).map_err(|e| e.to_string());
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
                    state.deployment.current_step_id = None;
                    state.deployment.completed_steps.clear();
                    state.deployment.failed_steps.clear();
                    state.deployment.finished_at = None;
                    state.deployment.logs.clear();
                    state.deployment.scroll_offset = 0;
                    state.deployment.spinner_frame = 0;
                    state.deployment.last_tick = None;
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
            InstallEvent::PhaseStarted { phase, message } => self
                .tx
                .send(InstallerEvent::DeployPhaseStarted { phase, message })
                .map_err(|err| err.to_string()),
            InstallEvent::StepStarted {
                step_id,
                display_name,
            } => self
                .tx
                .send(InstallerEvent::DeployStepStarted {
                    step_id,
                    display_name,
                })
                .map_err(|err| err.to_string()),
            InstallEvent::StepFinished { step_id, message } => self
                .tx
                .send(InstallerEvent::DeployStepFinished { step_id, message })
                .map_err(|err| err.to_string()),
            InstallEvent::Warning { code, message } => {
                self.emit_line(format!("Warning [{code}]: {message}"), None)
                    .await
            }
            InstallEvent::ArtifactRecorded { key, value } => {
                let display_value = if value.len() > 80 {
                    format!("{}…", &value[..80])
                } else {
                    value
                };
                self.emit_line(format!("Recorded artifact {key}={display_value}"), None)
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

        let screen_order = [
            ScreenId::Welcome,
            ScreenId::DoctorPreflight,
            ScreenId::PackSelection,
            ScreenId::ProfileSelection,
            ScreenId::MethodSelection,
            ScreenId::Review,
            ScreenId::DeployProgress,
            ScreenId::PostInstall,
        ];
        let current_idx = screen_order
            .iter()
            .position(|screen| *screen == state.screen)
            .unwrap_or(0);
        let checklist = Text::from(
            screen_order
                .iter()
                .enumerate()
                .map(|(idx, screen)| {
                    let style = if idx < current_idx {
                        Style::default().fg(Color::Green)
                    } else if idx == current_idx {
                        Style::default()
                            .fg(Color::Yellow)
                            .add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(Color::DarkGray)
                    };
                    let marker = if idx == current_idx { ">" } else { " " };
                    Line::from(vec![Span::styled(
                        format!("{marker} {}", screen_title(*screen)),
                        style,
                    )])
                })
                .collect::<Vec<_>>(),
        );

        frame.render_widget(
            Paragraph::new(checklist)
                .block(Block::default().title("Checklist").borders(Borders::ALL)),
            body[0],
        );

        let content = match state.screen {
            ScreenId::Welcome => screens::welcome::content(state),
            ScreenId::DoctorPreflight => screens::preflight::content(state),
            ScreenId::PackSelection => screens::pack_select::content(state),
            ScreenId::ProfileSelection => screens::profile_select::content(state),
            ScreenId::MethodSelection => screens::method_select::content(state),
            ScreenId::Review => screens::review::content(state),
            ScreenId::DeployProgress => screens::deploy::content_with_width(state, body[1].width as usize),
            ScreenId::PostInstall => screens::post_install::content(state),
        };

        let mut paragraph = Paragraph::new(content).block(
            Block::default()
                .title(screen_title(state.screen))
                .borders(Borders::ALL),
        );
        if state.screen == ScreenId::DeployProgress {
            paragraph = paragraph.scroll((state.deployment.scroll_offset as u16, 0));
        }
        frame.render_widget(paragraph, body[1]);

        frame.render_widget(Paragraph::new(footer_text(state)), areas[1]);

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

fn footer_text(state: &AppState) -> Text<'static> {
    if state.ui.help_visible {
        return Text::from(Line::from(vec![Span::styled(
            "Help open | Esc close | q quit",
            Style::default().fg(Color::DarkGray),
        )]));
    }

    state
        .errors
        .last()
        .map(|error| {
            Text::from(Line::from(vec![Span::styled(
                format!("Error: {} | ? help | q quit | b/h back", error.message),
                Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
            )]))
        })
        .unwrap_or_else(|| {
            Text::from(Line::from(vec![Span::styled(
                "Hints: Enter/Tab/l next | Space select | b/h back | arrows move | ? help | q quit",
                Style::default().fg(Color::DarkGray),
            )]))
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

#[derive(Debug, Deserialize)]
struct RegistryFile {
    packs: BTreeMap<String, RegistryPack>,
}

#[derive(Debug, Deserialize)]
struct RegistryPack {
    #[serde(rename = "type")]
    pack_type: String,
}

fn load_tui_packs(
    planner: &Planner,
) -> Result<Vec<crate::core::PackManifest>, crate::core::ManifestError> {
    let mut packs = planner.repo().load_all_packs()?;
    let packs_root = planner.repo().root().join("packs");
    let registry_path = packs_root.join("registry.yaml");
    let agent_ids = std::fs::read_to_string(&registry_path)
        .ok()
        .and_then(|raw| serde_yaml::from_str::<RegistryFile>(&raw).ok())
        .map(|registry| {
            registry
                .packs
                .into_iter()
                .filter_map(|(pack_id, pack)| (pack.pack_type == "agent").then_some(pack_id))
                .collect::<std::collections::BTreeSet<_>>()
        });

    packs.retain(|pack| {
        let pack_root = packs_root.join(&pack.id);
        let is_agent = agent_ids
            .as_ref()
            .map(|ids| ids.contains(&pack.id))
            .unwrap_or(true);
        is_agent
            && pack.schema_version > 0
            && pack_root.join("manifest.yaml").is_file()
            && pack_root.join("install.sh").is_file()
    });
    Ok(packs)
}
