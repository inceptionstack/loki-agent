//! Pack selection screen content.

use crate::tui::app::AppState;
use ratatui::text::{Line, Text};

pub fn content(state: &AppState) -> Text<'static> {
    let mut lines = vec![Line::from("Select a pack")];
    lines.push(Line::from(""));
    for (idx, pack) in state.packs.iter().enumerate() {
        let marker = if idx == state.request_draft.pack_cursor {
            ">"
        } else {
            " "
        };
        let experimental = if pack.experimental {
            " [experimental]"
        } else {
            ""
        };
        lines.push(Line::from(format!(
            "{marker} {} ({}){experimental}",
            pack.display_name, pack.id
        )));
        if idx == state.request_draft.pack_cursor {
            if let Some(description) = &pack.description {
                lines.push(Line::from(format!("    {description}")));
            }
        }
    }
    Text::from(lines)
}
