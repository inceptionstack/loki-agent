use crate::core::AdapterError;
use std::path::{Path, PathBuf};
use tokio::process::Command;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CommandSpec {
    pub(crate) program: String,
    pub(crate) args: Vec<String>,
    pub(crate) current_dir: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CommandOutput {
    pub(crate) status_code: Option<i32>,
    pub(crate) stdout: String,
    pub(crate) stderr: String,
}

impl CommandOutput {
    pub(crate) fn success(&self) -> bool {
        self.status_code == Some(0)
    }
}

pub(crate) async fn run_command(spec: &CommandSpec) -> Result<CommandOutput, AdapterError> {
    let mut command = build_command(spec);
    let output = command.output().await.map_err(|source| {
        if source.kind() == std::io::ErrorKind::NotFound {
            return AdapterError::Message(format!(
                "{} not found — install {} and re-run the installer",
                spec.program, spec.program
            ));
        }
        AdapterError::Message(format!(
            "Failed to run {} {} — {source}",
            spec.program,
            spec.args.join(" ")
        ))
    })?;

    Ok(CommandOutput {
        status_code: output.status.code(),
        stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
    })
}

pub(crate) fn spawn_child(spec: &CommandSpec) -> Result<tokio::process::Child, AdapterError> {
    build_command(spec).spawn().map_err(|source| {
        if source.kind() == std::io::ErrorKind::NotFound {
            return AdapterError::Message(format!(
                "{} not found — install {} and re-run the installer",
                spec.program, spec.program
            ));
        }
        AdapterError::Message(format!(
            "Failed to start {} {} — {source}",
            spec.program,
            spec.args.join(" ")
        ))
    })
}

pub(crate) fn resolve_repo_path(path: &str) -> Result<String, AdapterError> {
    let candidate = PathBuf::from(path);
    if candidate.is_absolute() && candidate.exists() {
        return Ok(candidate.display().to_string());
    }

    let cwd = std::env::current_dir().map_err(|source| {
        AdapterError::Message(format!("Failed to read current working directory — {source}"))
    })?;

    let direct = cwd.join(&candidate);
    if direct.exists() {
        return Ok(direct.display().to_string());
    }

    for ancestor in cwd.ancestors() {
        let repo_candidate = ancestor.join(&candidate);
        if repo_candidate.exists() {
            return Ok(repo_candidate.display().to_string());
        }
    }

    Err(AdapterError::Message(format!(
        "Required installer asset not found at {path} — verify the repo checkout is complete"
    )))
}

fn build_command(spec: &CommandSpec) -> Command {
    let mut command = Command::new(&spec.program);
    command.args(&spec.args);
    command.kill_on_drop(true);
    if let Some(current_dir) = &spec.current_dir {
        command.current_dir(Path::new(current_dir));
    }
    command
}
