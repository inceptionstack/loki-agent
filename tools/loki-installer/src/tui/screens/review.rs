//! Install plan review screen content.

use crate::tui::app::AppState;
use ratatui::text::{Line, Text};

pub fn content(state: &AppState) -> Text<'static> {
    let mut lines = vec![Line::from("Review install plan"), Line::from("")];
    if let Some(plan) = &state.plan {
        lines.push(Line::from(format!("Pack: {}", plan.resolved_pack.id)));
        lines.push(Line::from(format!("Profile: {}", plan.resolved_profile.id)));
        lines.push(Line::from(format!("Method: {}", plan.resolved_method.id)));
        lines.push(Line::from(format!("Region: {}", plan.resolved_region)));
        lines.push(Line::from(format!(
            "Stack name: {}",
            plan.resolved_stack_name.clone().unwrap_or_default()
        )));
        lines.push(Line::from(""));
        lines.push(Line::from("Steps:"));
        for step in &plan.deploy_steps {
            lines.push(Line::from(format!(
                " - [{}] {}",
                step.phase, step.display_name
            )));
        }
        if !plan.warnings.is_empty() {
            lines.push(Line::from(""));
            lines.push(Line::from("Warnings:"));
            for warning in &plan.warnings {
                lines.push(Line::from(format!(" ! {}", warning.message)));
            }
        }
    } else {
        lines.push(Line::from("No plan available."));
    }
    Text::from(lines)
}
