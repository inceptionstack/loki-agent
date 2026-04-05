//! JSON-backed install session persistence and resume helpers.

use crate::core::{InstallPhase, InstallPlan, InstallRequest, InstallSession, SessionFormat};
use chrono::Utc;
use std::fs;
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error("home directory not available")]
    HomeDirUnavailable,
    #[error("I/O error at {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("JSON error at {path}: {source}")]
    Json {
        path: String,
        #[source]
        source: serde_json::Error,
    },
    #[error("session file not found for {0}")]
    NotFound(String),
}

pub fn session_root() -> Result<PathBuf, SessionError> {
    let home = std::env::var("HOME").map_err(|_| SessionError::HomeDirUnavailable)?;
    Ok(PathBuf::from(home)
        .join(".local")
        .join("state")
        .join("loki-installer")
        .join("sessions"))
}

pub fn create_session(request: InstallRequest, plan: Option<InstallPlan>) -> InstallSession {
    let now = Utc::now();
    InstallSession {
        session_id: Uuid::new_v4().to_string(),
        installer_version: env!("CARGO_PKG_VERSION").to_string(),
        engine: request.engine,
        mode: request.mode,
        request,
        plan,
        phase: InstallPhase::ValidateEnvironment,
        started_at: now,
        updated_at: now,
        artifacts: Default::default(),
        status_summary: None,
    }
}

pub fn persist_session(session: &InstallSession) -> Result<PathBuf, SessionError> {
    let root = session_root()?;
    fs::create_dir_all(&root).map_err(|err| SessionError::Io {
        path: root.display().to_string(),
        source: err,
    })?;
    set_directory_permissions(&root)?;

    let final_path = root.join(format!("{}.json", session.session_id));
    let tmp_path = root.join(format!("{}.tmp", session.session_id));
    let raw = serde_json::to_vec_pretty(session).map_err(|err| SessionError::Json {
        path: final_path.display().to_string(),
        source: err,
    })?;
    write_private_file(&tmp_path, &raw)?;
    fs::rename(&tmp_path, &final_path).map_err(|err| SessionError::Io {
        path: final_path.display().to_string(),
        source: err,
    })?;
    set_file_permissions(&final_path)?;

    let latest = root.join("latest.json");
    let latest_payload = serde_json::json!({
        "session_id": session.session_id,
        "format": SessionFormat::Json,
    });
    let latest_raw =
        serde_json::to_vec_pretty(&latest_payload).map_err(|err| SessionError::Json {
            path: latest.display().to_string(),
            source: err,
        })?;
    write_private_file(&latest, &latest_raw)?;

    Ok(final_path)
}

pub fn load_session(session_id: &str) -> Result<InstallSession, SessionError> {
    load_session_file(session_root()?.join(format!("{session_id}.json")))
}

pub fn load_latest_session() -> Result<InstallSession, SessionError> {
    let root = session_root()?;
    let latest = root.join("latest.json");
    if !latest.exists() {
        return Err(SessionError::NotFound("latest".into()));
    }
    let raw = fs::read_to_string(&latest).map_err(|err| SessionError::Io {
        path: latest.display().to_string(),
        source: err,
    })?;
    let value: serde_json::Value =
        serde_json::from_str(&raw).map_err(|err| SessionError::Json {
            path: latest.display().to_string(),
            source: err,
        })?;
    let session_id = value
        .get("session_id")
        .and_then(|value| value.as_str())
        .ok_or_else(|| SessionError::NotFound("latest".into()))?;
    load_session(session_id)
}

fn load_session_file(path: PathBuf) -> Result<InstallSession, SessionError> {
    if !path.exists() {
        return Err(SessionError::NotFound(path.display().to_string()));
    }
    let raw = fs::read_to_string(&path).map_err(|err| SessionError::Io {
        path: path.display().to_string(),
        source: err,
    })?;
    serde_json::from_str(&raw).map_err(|err| SessionError::Json {
        path: path.display().to_string(),
        source: err,
    })
}

pub fn session_path_for(session: &InstallSession) -> Result<PathBuf, SessionError> {
    Ok(session_root()?.join(format!("{}.json", session.session_id)))
}

pub fn update_session_phase(session: &mut InstallSession, phase: InstallPhase) {
    session.phase = phase;
    session.updated_at = Utc::now();
}

pub fn touch_session(session: &mut InstallSession) {
    session.updated_at = Utc::now();
}

pub fn session_path_hint(path: &Path) -> String {
    path.display().to_string()
}

fn write_private_file(path: &Path, contents: &[u8]) -> Result<(), SessionError> {
    let mut file = open_private_file(path)?;
    std::io::Write::write_all(&mut file, contents).map_err(|err| SessionError::Io {
        path: path.display().to_string(),
        source: err,
    })?;
    file.sync_all().map_err(|err| SessionError::Io {
        path: path.display().to_string(),
        source: err,
    })?;
    Ok(())
}

fn open_private_file(path: &Path) -> Result<std::fs::File, SessionError> {
    let mut options = OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    options.mode(0o600);
    options.open(path).map_err(|err| SessionError::Io {
        path: path.display().to_string(),
        source: err,
    })
}

fn set_directory_permissions(path: &Path) -> Result<(), SessionError> {
    #[cfg(unix)]
    {
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|err| {
            SessionError::Io {
                path: path.display().to_string(),
                source: err,
            }
        })?;
    }
    Ok(())
}

fn set_file_permissions(path: &Path) -> Result<(), SessionError> {
    #[cfg(unix)]
    {
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|err| {
            SessionError::Io {
                path: path.display().to_string(),
                source: err,
            }
        })?;
    }
    Ok(())
}
