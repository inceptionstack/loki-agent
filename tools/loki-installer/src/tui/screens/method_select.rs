//! Deployment method selection screen content.

use crate::tui::app::AppState;
use ratatui::text::{Line, Text};

pub fn content(state: &AppState) -> Text<'static> {
    let mut lines = vec![Line::from("Select a deployment method"), Line::from("")];
    for (idx, method) in state.methods.iter().enumerate() {
        let marker = if idx == state.request_draft.method_cursor {
            ">"
        } else {
            " "
        };
        lines.push(Line::from(format!(
            "{marker} {} ({})",
            method.display_name, method.id
        )));
        if idx == state.request_draft.method_cursor {
            if let Some(description) = &method.description {
                lines.push(Line::from(format!("    {description}")));
            }
            lines.push(Line::from(format!(
                "    Tools: {}",
                method.required_tools.join(", ")
            )));
        }
    }
    Text::from(lines)
}
