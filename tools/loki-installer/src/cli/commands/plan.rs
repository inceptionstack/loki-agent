//! `plan` subcommand.

use crate::cli::args::PlanArgs;
use crate::core::Planner;
use color_eyre::eyre::{Result, eyre};

pub async fn run(args: PlanArgs) -> Result<()> {
    let planner = Planner::discover()?;
    let request = args.install.to_request();
    if request.pack.is_empty() {
        return Err(eyre!("--pack is required for planning"));
    }
    let plan = planner.build_plan(request).await?;
    if args.install.json {
        println!("{}", serde_json::to_string_pretty(&plan)?);
    } else {
        println!(
            "Plan for pack={} profile={} method={} region={}",
            plan.resolved_pack.id,
            plan.resolved_profile.id,
            plan.resolved_method.id,
            plan.resolved_region
        );
        for step in &plan.deploy_steps {
            println!(" - [{}] {}", step.phase, step.display_name);
        }
        for warning in &plan.warnings {
            println!(" ! {}: {}", warning.code, warning.message);
        }
    }
    Ok(())
}
