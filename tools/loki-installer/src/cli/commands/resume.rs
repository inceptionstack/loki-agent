//! `resume` subcommand.

use crate::cli::args::ResumeArgs;
use crate::cli::output::{print_human_line, print_json_line};
use crate::core::{Planner, load_latest_session, load_session};
use color_eyre::eyre::Result;

pub async fn run(args: ResumeArgs, for_agent: bool) -> Result<()> {
    let planner = Planner::discover()?;
    let mut session = match args.session.as_deref() {
        Some(session_id) => load_session(session_id)?,
        None => load_latest_session()?,
    };
    planner.resume_install(&mut session).await?;
    if args.json {
        print_json_line(&serde_json::to_value(&session)?)?;
    } else {
        print_human_line(
            for_agent,
            format!(
                "Resumed session {} to phase {}",
                session.session_id, session.phase
            ),
        )?;
    }
    Ok(())
}
