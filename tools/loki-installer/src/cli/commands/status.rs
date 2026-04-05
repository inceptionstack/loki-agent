//! `status` subcommand.

use crate::cli::args::StatusArgs;
use crate::core::{Planner, load_latest_session, load_session};
use color_eyre::Result;

pub async fn run(args: StatusArgs) -> Result<()> {
    let planner = Planner::discover()?;
    let session = match args.session.as_deref() {
        Some(session_id) => load_session(session_id)?,
        None => load_latest_session()?,
    };
    let status = planner.status(&session).await?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&status)?);
    } else {
        println!("Deployed: {}", status.deployed);
        println!("Pack: {}", status.pack);
        println!("Profile: {}", status.profile);
        println!("Method: {}", status.method);
        println!("Region: {}", status.region.unwrap_or_default());
        println!("Stack Name: {}", status.stack_name.unwrap_or_default());
        println!("Stack Status: {}", status.stack_status.unwrap_or_default());
        println!(
            "Instance Health: {}",
            status.instance_health.unwrap_or_default()
        );
        println!("Last Updated: {}", status.last_updated_at);
    }
    Ok(())
}
