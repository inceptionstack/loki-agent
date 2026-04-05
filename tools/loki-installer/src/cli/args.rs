//! CLI argument models and request normalization.

use crate::core::{DeployMethodId, InstallMode, InstallRequest, InstallerEngine};
use clap::{Args, Parser, Subcommand, ValueEnum};
use std::collections::BTreeMap;

#[derive(Debug, Parser)]
#[command(name = "loki-installer", about = "Loki Agent Installer V2")]
pub struct Cli {
    #[arg(long, global = true)]
    pub for_agent: bool,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    Install(InstallArgs),
    Doctor(DoctorArgs),
    Plan(PlanArgs),
    Resume(ResumeArgs),
    Uninstall(UninstallArgs),
    Status(StatusArgs),
}

#[derive(Debug, Clone, Args)]
pub struct InstallArgs {
    #[arg(long, value_enum, default_value_t = EngineArg::V2)]
    pub engine: EngineArg,
    #[arg(long)]
    pub non_interactive: bool,
    #[arg(short = 'y', long = "yes")]
    pub auto_yes: bool,
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub pack: Option<String>,
    #[arg(long)]
    pub profile: Option<String>,
    #[arg(long, value_enum)]
    pub method: Option<MethodArg>,
    #[arg(long)]
    pub region: Option<String>,
    #[arg(long)]
    pub stack_name: Option<String>,
    #[arg(long = "option", value_parser = parse_key_val::<String, String>)]
    pub extra_options: Vec<(String, String)>,
    #[arg(long)]
    pub resume: Option<String>,
}

#[derive(Debug, Clone, Args)]
pub struct DoctorArgs {
    #[arg(long)]
    pub pack: Option<String>,
    #[arg(long)]
    pub profile: Option<String>,
    #[arg(long, value_enum)]
    pub method: Option<MethodArg>,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct PlanArgs {
    #[command(flatten)]
    pub install: InstallArgs,
}

#[derive(Debug, Clone, Args)]
pub struct ResumeArgs {
    #[arg(long)]
    pub session: Option<String>,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct UninstallArgs {
    #[arg(long)]
    pub session: Option<String>,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct StatusArgs {
    #[arg(long)]
    pub session: Option<String>,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum EngineArg {
    V1,
    V2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum MethodArg {
    Cfn,
    Terraform,
}

impl From<EngineArg> for InstallerEngine {
    fn from(value: EngineArg) -> Self {
        match value {
            EngineArg::V1 => InstallerEngine::V1,
            EngineArg::V2 => InstallerEngine::V2,
        }
    }
}

impl From<MethodArg> for DeployMethodId {
    fn from(value: MethodArg) -> Self {
        match value {
            MethodArg::Cfn => DeployMethodId::Cfn,
            MethodArg::Terraform => DeployMethodId::Terraform,
        }
    }
}

impl InstallArgs {
    pub fn to_request(&self) -> InstallRequest {
        let mode = if self.non_interactive {
            InstallMode::NonInteractive
        } else {
            InstallMode::Interactive
        };
        InstallRequest {
            engine: self.engine.into(),
            mode,
            pack: self.pack.clone().unwrap_or_default(),
            profile: self.profile.clone(),
            method: self.method.map(Into::into),
            region: self.region.clone(),
            stack_name: self.stack_name.clone(),
            auto_yes: self.auto_yes || self.non_interactive,
            json_output: self.json,
            resume_session_id: self.resume.clone(),
            extra_options: self
                .extra_options
                .iter()
                .cloned()
                .collect::<BTreeMap<_, _>>(),
        }
    }
}

impl DoctorArgs {
    pub fn to_request(&self) -> Option<InstallRequest> {
        self.pack.as_ref()?;
        Some(InstallRequest {
            engine: InstallerEngine::V2,
            mode: InstallMode::NonInteractive,
            pack: self.pack.clone().unwrap_or_default(),
            profile: self.profile.clone(),
            method: self.method.map(Into::into),
            region: None,
            stack_name: None,
            auto_yes: true,
            json_output: self.json,
            resume_session_id: None,
            extra_options: BTreeMap::new(),
        })
    }
}

fn parse_key_val<K, V>(s: &str) -> Result<(K, V), String>
where
    K: std::str::FromStr,
    V: std::str::FromStr,
    K::Err: std::fmt::Display,
    V::Err: std::fmt::Display,
{
    let pos = s
        .find('=')
        .ok_or_else(|| format!("invalid KEY=value: no `=` found in `{s}`"))?;
    Ok((
        s[..pos].parse().map_err(|e| format!("{e}"))?,
        s[pos + 1..].parse().map_err(|e| format!("{e}"))?,
    ))
}

#[cfg(test)]
mod tests {
    use super::{Cli, Command, MethodArg};
    use clap::Parser;

    #[test]
    fn parses_install_options() {
        let cli = Cli::parse_from([
            "loki-installer",
            "--for-agent",
            "install",
            "--pack",
            "openclaw",
            "--method",
            "terraform",
            "--option",
            "workspace=dev",
        ]);

        assert!(cli.for_agent);

        let Command::Install(args) = cli.command else {
            panic!("expected install command");
        };

        assert_eq!(args.pack.as_deref(), Some("openclaw"));
        assert_eq!(args.method, Some(MethodArg::Terraform));
        assert_eq!(args.extra_options.len(), 1);
    }
}
