//! Profile selection screen content.

use crate::tui::app::AppState;
use ratatui::text::{Line, Text};

pub fn content(state: &AppState) -> Text<'static> {
    let mut lines = vec![Line::from("Select a profile"), Line::from("")];
    for (idx, profile) in state.profiles.iter().enumerate() {
        let marker = if idx == state.request_draft.profile_cursor {
            ">"
        } else {
            " "
        };
        lines.push(Line::from(format!(
            "{marker} {} ({})",
            profile.display_name, profile.id
        )));
        if idx == state.request_draft.profile_cursor {
            if let Some(description) = &profile.description {
                lines.push(Line::from(format!("    {description}")));
            }
        }
    }
    Text::from(lines)
}
