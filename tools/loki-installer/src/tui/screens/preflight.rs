//! Doctor/preflight screen content.

use crate::tui::app::AppState;
use ratatui::text::{Line, Text};

pub fn content(state: &AppState) -> Text<'static> {
    let mut lines = vec![Line::from("Preflight results")];
    if let Some(report) = &state.doctor.report {
        lines.push(Line::from(""));
        for check in &report.checks {
            let icon = if check.passed { "[OK]" } else { "[FAIL]" };
            lines.push(Line::from(format!(
                "{icon} {}: {}",
                check.check.display_name, check.message
            )));
        }
    } else {
        lines.push(Line::from(""));
        lines.push(Line::from("Press Enter to run doctor checks."));
    }
    Text::from(lines)
}
