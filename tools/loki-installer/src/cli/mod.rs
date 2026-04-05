//! Command-line entrypoints and argument parsing.

pub mod args;
mod commands;

use crate::cli::args::{Cli, Command};
use clap::Parser;
use color_eyre::Result;

pub async fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Install(args) => commands::install::run(args).await,
        Command::Doctor(args) => commands::doctor::run(args).await,
        Command::Plan(args) => commands::plan::run(args).await,
        Command::Resume(args) => commands::resume::run(args).await,
        Command::Uninstall(args) => commands::uninstall::run(args).await,
        Command::Status(args) => commands::status::run(args).await,
    }
}
