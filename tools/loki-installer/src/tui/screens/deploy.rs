//! Deployment progress screen content.

use crate::tui::app::AppState;
use ratatui::{
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
};

pub const SPINNER: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

pub fn content(state: &AppState) -> Text<'static> {
    content_with_width(state, 80)
}

pub fn content_with_width(state: &AppState, max_width: usize) -> Text<'static> {
    let mut lines = vec![Line::from("Deployment progress"), Line::from("")];
    if let Some(phase) = state.deployment.current_phase {
        lines.push(Line::from(vec![
            Span::styled("Current phase: ", Style::default().fg(Color::Cyan)),
            Span::raw(phase.to_string()),
        ]));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(vec![Span::styled(
        "Steps:",
        Style::default().fg(Color::Cyan),
    )]));
    if let Some(plan) = &state.plan {
        for step in &plan.deploy_steps {
            let (marker, style) = if state.deployment.failed_steps.contains(&step.id) {
                (
                    "✗",
                    Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
                )
            } else if state.deployment.current_step_id.as_deref() == Some(step.id.as_str()) {
                (
                    SPINNER[state.deployment.spinner_frame % SPINNER.len()],
                    Style::default()
                        .fg(Color::Yellow)
                        .add_modifier(Modifier::BOLD),
                )
            } else if state.deployment.completed_steps.contains(&step.id) {
                (
                    "✓",
                    Style::default()
                        .fg(Color::Green)
                        .add_modifier(Modifier::BOLD),
                )
            } else {
                ("•", Style::default().fg(Color::DarkGray))
            };
            lines.push(Line::from(vec![
                Span::styled(format!("{marker} "), style),
                Span::styled(
                    format!("[{}] ", step.phase),
                    Style::default().fg(Color::Cyan),
                ),
                Span::raw(step.display_name.clone()),
            ]));
        }
    }
    lines.push(Line::from(""));
    lines.push(Line::from(vec![Span::styled(
        "Logs:",
        Style::default().fg(Color::Cyan),
    )]));
    let total_logs = state.deployment.logs.len();
    let visible_lines = 30usize;
    let clamped_offset = state
        .deployment
        .scroll_offset
        .min(total_logs.saturating_sub(visible_lines));
    let end = total_logs.saturating_sub(clamped_offset);
    let start = end.saturating_sub(visible_lines);
    for line in &state.deployment.logs[start..end] {
        // Truncate long lines to avoid horizontal overflow
        let max_line = max_width.saturating_sub(6);
        let display = if line.len() > max_line {
            format!(" - {}…", &line[..max_line])
        } else {
            format!(" - {line}")
        };
        lines.push(Line::from(vec![Span::styled(
            display,
            Style::default().fg(Color::DarkGray),
        )]));
    }
    Text::from(lines)
}
