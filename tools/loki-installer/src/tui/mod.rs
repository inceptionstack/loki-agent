//! Terminal UI flow for interactive install planning and execution.

pub mod app;
pub mod events;
pub mod runtime;
pub mod screens;
pub mod update;

use crate::core::Planner;
use color_eyre::Result;

pub async fn run(planner: Planner) -> Result<()> {
    runtime::run(planner).await
}
