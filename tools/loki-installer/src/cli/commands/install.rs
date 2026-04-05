//! `install` subcommand.

use crate::cli::args::InstallArgs;
use crate::cli::output::{ForAgentEventSink, print_human_line, print_json_line};
use crate::core::{InstallMode, Planner};
use crate::tui;
use color_eyre::eyre::{Result, eyre};
use std::io;
use std::time::Instant;

pub async fn run(args: InstallArgs, for_agent: bool) -> Result<()> {
    let planner = Planner::discover()?;
    let request = args.to_request();

    if request.mode == InstallMode::Interactive && !request.auto_yes {
        return tui::run(planner).await;
    }

    if request.pack.is_empty() {
        return Err(eyre!("--pack is required for non-interactive install"));
    }

    let plan = planner.build_plan(request).await?;
    let started_at = Instant::now();

    if for_agent {
        let mut session = planner.create_install_session(plan)?;
        let mut sink = ForAgentEventSink::new(io::stdout());
        match planner
            .execute_install_with_sink(&mut session, &mut sink)
            .await
        {
            Ok(()) => {
                sink.emit_install_complete(&session, started_at.elapsed().as_millis())?;
                if args.json {
                    print_human_line(for_agent, serde_json::to_string_pretty(&session)?)?;
                }
                Ok(())
            }
            Err(error) => {
                sink.emit_install_failed(
                    &session.session_id,
                    &error.to_string(),
                    started_at.elapsed().as_millis(),
                )?;
                Err(error.into())
            }
        }
    } else {
        let session = planner.start_install(plan).await?;
        if args.json {
            print_json_line(&serde_json::to_value(&session)?)?;
        } else {
            print_human_line(
                false,
                format!(
                    "Install finished for pack={} profile={} method={} session={}",
                    session.request.pack,
                    session.request.profile.clone().unwrap_or_default(),
                    session
                        .plan
                        .as_ref()
                        .map(|plan| plan.resolved_method.id.to_string())
                        .unwrap_or_default(),
                    session.session_id
                ),
            )?;
        }
        Ok(())
    }
}
