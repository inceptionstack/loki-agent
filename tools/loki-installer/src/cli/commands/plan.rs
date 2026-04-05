//! `plan` subcommand.

use crate::cli::args::PlanArgs;
use crate::cli::output::{plan_result_json, print_human_line, print_json_line};
use crate::core::Planner;
use color_eyre::eyre::{Result, eyre};

pub async fn run(args: PlanArgs, for_agent: bool) -> Result<()> {
    let planner = Planner::discover()?;
    let request = args.install.to_request();
    if request.pack.is_empty() {
        return Err(eyre!("--pack is required for planning"));
    }
    let plan = planner.build_plan(request).await?;
    if for_agent {
        print_json_line(&plan_result_json(&plan))?;
    } else if args.install.json {
        print_json_line(&serde_json::to_value(&plan)?)?;
    } else {
        print_human_line(
            for_agent,
            format!(
                "Plan for pack={} profile={} method={} region={}",
                plan.resolved_pack.id,
                plan.resolved_profile.id,
                plan.resolved_method.id,
                plan.resolved_region
            ),
        )?;
        for step in &plan.deploy_steps {
            print_human_line(
                for_agent,
                format!(" - [{}] {}", step.phase, step.display_name),
            )?;
        }
        for warning in &plan.warnings {
            print_human_line(
                for_agent,
                format!(" ! {}: {}", warning.code, warning.message),
            )?;
        }
    }
    Ok(())
}
