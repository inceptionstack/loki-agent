//! `resume` subcommand.

use crate::cli::args::ResumeArgs;
use crate::core::{Planner, load_latest_session, load_session};
use color_eyre::eyre::Result;

pub async fn run(args: ResumeArgs) -> Result<()> {
    let planner = Planner::discover()?;
    let mut session = match args.session.as_deref() {
        Some(session_id) => load_session(session_id)?,
        None => load_latest_session()?,
    };
    planner.resume_install(&mut session).await?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&session)?);
    } else {
        println!(
            "Resumed session {} to phase {}",
            session.session_id, session.phase
        );
    }
    Ok(())
}
