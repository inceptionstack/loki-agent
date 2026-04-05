//! `uninstall` subcommand.

use crate::cli::args::UninstallArgs;
use crate::cli::output::{print_human_line, print_json_line};
use crate::core::{Planner, load_latest_session, load_session};
use color_eyre::Result;

pub async fn run(args: UninstallArgs, for_agent: bool) -> Result<()> {
    let planner = Planner::discover()?;
    let session = match args.session.as_deref() {
        Some(session_id) => load_session(session_id)?,
        None => load_latest_session()?,
    };
    planner.uninstall(&session).await?;
    if args.json {
        print_json_line(&serde_json::json!({
            "session_id": session.session_id,
            "uninstall": "requested"
        }))?;
    } else {
        print_human_line(
            for_agent,
            format!("Uninstall requested for session {}", session.session_id),
        )?;
    }
    Ok(())
}
