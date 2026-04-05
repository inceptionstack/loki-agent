//! Command-line entrypoints and argument parsing.

pub mod args;
mod commands;
mod output;

use crate::cli::args::{Cli, Command};
use clap::Parser;
use color_eyre::Result;

pub async fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Install(args) => commands::install::run(args, cli.for_agent).await,
        Command::Doctor(args) => commands::doctor::run(args, cli.for_agent).await,
        Command::Plan(args) => commands::plan::run(args, cli.for_agent).await,
        Command::Resume(args) => commands::resume::run(args, cli.for_agent).await,
        Command::Uninstall(args) => commands::uninstall::run(args, cli.for_agent).await,
        Command::Status(args) => commands::status::run(args, cli.for_agent).await,
    }
}
