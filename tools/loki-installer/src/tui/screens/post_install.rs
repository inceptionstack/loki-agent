//! Post-install summary screen content.

use crate::tui::app::AppState;
use ratatui::text::{Line, Text};

pub fn content(state: &AppState) -> Text<'static> {
    let mut lines = vec![Line::from("Post-install"), Line::from("")];
    if let Some(session) = &state.session {
        lines.push(Line::from(format!("Session: {}", session.session_id)));
        if let Some(plan) = &session.plan {
            lines.push(Line::from(format!(
                "Status: loki-installer status --session {}",
                session.session_id
            )));
            for step in &plan.post_install_steps {
                lines.push(Line::from(format!(
                    "{}: {}",
                    step.display_name, step.instruction
                )));
            }
        }
    } else {
        lines.push(Line::from("Deployment session saved."));
    }
    Text::from(lines)
}
