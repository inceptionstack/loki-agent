//! Loki Installer V2 binary entrypoint.

use color_eyre::Result;

#[tokio::main]
async fn main() -> Result<()> {
    color_eyre::install()?;
    loki_installer::cli::run().await
}
