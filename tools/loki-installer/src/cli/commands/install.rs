//! `install` subcommand.

use crate::cli::args::InstallArgs;
use crate::core::{InstallMode, Planner};
use crate::tui;
use color_eyre::eyre::{Result, eyre};

pub async fn run(args: InstallArgs) -> Result<()> {
    let planner = Planner::discover()?;
    let request = args.to_request();

    if request.mode == InstallMode::Interactive && !request.auto_yes {
        return tui::run(planner).await;
    }

    if request.pack.is_empty() {
        return Err(eyre!("--pack is required for non-interactive install"));
    }

    let session = planner
        .start_install(planner.build_plan(request).await?)
        .await?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&session)?);
    } else {
        println!(
            "Install finished for pack={} profile={} method={} session={}",
            session.request.pack,
            session.request.profile.clone().unwrap_or_default(),
            session
                .plan
                .as_ref()
                .map(|plan| plan.resolved_method.id.to_string())
                .unwrap_or_default(),
            session.session_id
        );
    }
    Ok(())
}
