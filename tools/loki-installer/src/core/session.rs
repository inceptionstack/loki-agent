//! JSON-backed install session persistence and resume helpers.

use crate::core::{InstallPhase, InstallPlan, InstallRequest, InstallSession, SessionFormat};
use chrono::Utc;
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

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

    let final_path = root.join(format!("{}.json", session.session_id));
    let tmp_path = root.join(format!("{}.tmp", session.session_id));
    let raw = serde_json::to_vec_pretty(session).map_err(|err| SessionError::Json {
        path: final_path.display().to_string(),
        source: err,
    })?;
    fs::write(&tmp_path, raw).map_err(|err| SessionError::Io {
        path: tmp_path.display().to_string(),
        source: err,
    })?;
    fs::rename(&tmp_path, &final_path).map_err(|err| SessionError::Io {
        path: final_path.display().to_string(),
        source: err,
    })?;

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
    fs::write(&latest, latest_raw).map_err(|err| SessionError::Io {
        path: latest.display().to_string(),
        source: err,
    })?;

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
