//! Welcome screen content.

use ratatui::text::{Line, Text};

pub fn content() -> Text<'static> {
    Text::from(vec![
        Line::from("Installer V2 deploys Loki packs with a shared core for CLI and TUI."),
        Line::from(""),
        Line::from("Press Enter to run preflight checks, or q to quit."),
    ])
}
