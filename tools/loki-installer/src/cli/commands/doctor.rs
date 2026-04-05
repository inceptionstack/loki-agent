//! `doctor` subcommand.

use crate::cli::args::DoctorArgs;
use crate::cli::output::{doctor_result_json, print_human_line, print_json_line};
use crate::core::Planner;
use color_eyre::Result;

pub async fn run(args: DoctorArgs, for_agent: bool) -> Result<()> {
    let planner = Planner::discover()?;
    let report = planner.run_doctor(args.to_request().as_ref())?;
    if for_agent {
        print_json_line(&doctor_result_json(&report))?;
    } else if args.json {
        let payload = report
            .checks
            .iter()
            .map(|check| {
                serde_json::json!({
                    "id": check.check.id,
                    "display_name": check.check.display_name,
                    "required": check.check.required,
                    "passed": check.passed,
                    "message": check.message,
                })
            })
            .collect::<Vec<_>>();
        print_json_line(&serde_json::to_value(&payload)?)?;
    } else {
        print_human_line(
            for_agent,
            format!("Doctor report at {}", report.generated_at),
        )?;
        for check in report.checks {
            let icon = if check.passed { "OK" } else { "FAIL" };
            print_human_line(
                for_agent,
                format!("[{icon}] {}: {}", check.check.display_name, check.message),
            )?;
        }
    }
    Ok(())
}
