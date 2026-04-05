//! `doctor` subcommand.

use crate::cli::args::DoctorArgs;
use crate::core::Planner;
use color_eyre::Result;

pub async fn run(args: DoctorArgs) -> Result<()> {
    let planner = Planner::discover()?;
    let report = planner.run_doctor(args.to_request().as_ref())?;
    if args.json {
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
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        println!("Doctor report at {}", report.generated_at);
        for check in report.checks {
            let icon = if check.passed { "OK" } else { "FAIL" };
            println!("[{icon}] {}: {}", check.check.display_name, check.message);
        }
    }
    Ok(())
}
