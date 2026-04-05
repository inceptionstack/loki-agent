//! `status` subcommand.

use crate::cli::args::StatusArgs;
use crate::cli::output::{print_human_line, print_json_line, status_result_json};
use crate::core::{Planner, load_latest_session, load_session};
use color_eyre::Result;

pub async fn run(args: StatusArgs, for_agent: bool) -> Result<()> {
    let planner = Planner::discover()?;
    let session = match args.session.as_deref() {
        Some(session_id) => load_session(session_id)?,
        None => load_latest_session()?,
    };
    let status = planner.status(&session).await?;
    if for_agent {
        print_json_line(&status_result_json(&session, &status))?;
    } else if args.json {
        print_json_line(&serde_json::to_value(&status)?)?;
    } else {
        print_human_line(for_agent, format!("Deployed: {}", status.deployed))?;
        print_human_line(for_agent, format!("Pack: {}", status.pack))?;
        print_human_line(for_agent, format!("Profile: {}", status.profile))?;
        print_human_line(for_agent, format!("Method: {}", status.method))?;
        print_human_line(
            for_agent,
            format!("Region: {}", status.region.unwrap_or_default()),
        )?;
        print_human_line(
            for_agent,
            format!("Stack Name: {}", status.stack_name.unwrap_or_default()),
        )?;
        print_human_line(
            for_agent,
            format!("Stack Status: {}", status.stack_status.unwrap_or_default()),
        )?;
        print_human_line(
            for_agent,
            format!(
                "Instance Health: {}",
                status.instance_health.unwrap_or_default()
            ),
        )?;
        print_human_line(
            for_agent,
            format!("Last Updated: {}", status.last_updated_at),
        )?;
    }
    Ok(())
}
