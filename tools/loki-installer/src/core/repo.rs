//! Repo root detection and cache-backed clone/update logic.

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

const DEFAULT_REPO_URL: &str = "https://github.com/inceptionstack/loki-agent.git";
const CACHE_STALE_AFTER: Duration = Duration::from_secs(60 * 60);

#[derive(Debug, thiserror::Error)]
pub enum RepoError {
    #[error("failed to read current working directory: {0}")]
    CurrentDir(#[source] std::io::Error),
    #[error("invalid repo path override: {0}")]
    InvalidOverride(String),
    #[error("failed to resolve XDG data directory")]
    DataDirUnavailable,
    #[error("git command failed: {0}")]
    Git(String),
    #[error("repo root not available: {0}")]
    Unavailable(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoSyncEvent {
    pub action: String,
    pub path: PathBuf,
    pub ref_name: String,
}

#[derive(Debug, Clone)]
pub struct RepoProbe {
    pub root: Option<PathBuf>,
    pub sync_event: Option<RepoSyncEvent>,
    pub error: Option<String>,
}

pub fn detect_repo_root() -> Result<Option<PathBuf>, RepoError> {
    let cwd = std::env::current_dir().map_err(RepoError::CurrentDir)?;
    Ok(detect_repo_root_from(&cwd))
}

pub fn detect_repo_root_from(start: &Path) -> Option<PathBuf> {
    for dir in start.ancestors() {
        if is_repo_root(dir) {
            return Some(dir.to_path_buf());
        }
    }
    None
}

pub fn probe_repo_root(override_path: Option<&Path>) -> RepoProbe {
    match resolve_repo_root(override_path) {
        Ok(probe) => probe,
        Err(error) => RepoProbe {
            root: None,
            sync_event: None,
            error: Some(error.to_string()),
        },
    }
}

pub fn resolve_repo_root(override_path: Option<&Path>) -> Result<RepoProbe, RepoError> {
    if let Some(path) = override_path {
        let root = fs::canonicalize(path)
            .map_err(|_| RepoError::InvalidOverride(path.display().to_string()))?;
        if !is_repo_root(&root) {
            return Err(RepoError::InvalidOverride(root.display().to_string()));
        }
        return Ok(RepoProbe {
            root: Some(root),
            sync_event: None,
            error: None,
        });
    }

    if let Some(root) = detect_repo_root()? {
        return Ok(RepoProbe {
            root: Some(root),
            sync_event: None,
            error: None,
        });
    }

    let sync = sync_cached_repo()?;
    Ok(RepoProbe {
        root: Some(sync.path.clone()),
        sync_event: Some(sync),
        error: None,
    })
}

pub fn is_repo_root(path: &Path) -> bool {
    path.join("install.sh").is_file()
        && path.join("packs").is_dir()
        && path.join("profiles").is_dir()
        && path.join("methods").is_dir()
        && path.join("deploy").is_dir()
}

fn sync_cached_repo() -> Result<RepoSyncEvent, RepoError> {
    let repo_dir = cache_repo_dir()?;
    let repo_url = repo_url();
    let desired_ref = desired_repo_ref();

    if !repo_dir.exists() {
        if let Some(parent) = repo_dir.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                RepoError::Unavailable(format!(
                    "failed to create repo cache directory {}: {error}",
                    parent.display()
                ))
            })?;
        }
        let ref_name = select_remote_ref(&repo_url, &desired_ref).unwrap_or_else(|_| "main".into());
        run_git(
            [
                OsStr::new("clone"),
                OsStr::new("--depth"),
                OsStr::new("1"),
                OsStr::new("--branch"),
                OsStr::new(&ref_name),
                OsStr::new(&repo_url),
                repo_dir.as_os_str(),
            ],
            None,
        )?;
        ensure_cached_repo_valid(&repo_dir)?;
        return Ok(RepoSyncEvent {
            action: "clone".into(),
            path: repo_dir,
            ref_name,
        });
    }

    ensure_cached_repo_valid(&repo_dir)?;

    if cache_is_stale(&repo_dir)? {
        let ref_name = select_remote_ref(&repo_url, &desired_ref).unwrap_or_else(|_| "main".into());
        run_git(
            [
                OsStr::new("-C"),
                repo_dir.as_os_str(),
                OsStr::new("fetch"),
                OsStr::new("--tags"),
                OsStr::new("origin"),
            ],
            None,
        )?;
        checkout_cached_ref(&repo_dir, &ref_name)?;
        if ref_name == "main" {
            run_git(
                [
                    OsStr::new("-C"),
                    repo_dir.as_os_str(),
                    OsStr::new("pull"),
                    OsStr::new("--ff-only"),
                    OsStr::new("origin"),
                    OsStr::new("main"),
                ],
                None,
            )?;
        }
        ensure_cached_repo_valid(&repo_dir)?;
        return Ok(RepoSyncEvent {
            action: "pull".into(),
            path: repo_dir,
            ref_name,
        });
    }

    let current_ref = current_cached_ref(&repo_dir).unwrap_or_else(|| "main".into());
    if current_ref != desired_ref {
        run_git(
            [
                OsStr::new("-C"),
                repo_dir.as_os_str(),
                OsStr::new("fetch"),
                OsStr::new("--tags"),
                OsStr::new("origin"),
            ],
            None,
        )?;
        let ref_name = select_remote_ref(&repo_url, &desired_ref).unwrap_or_else(|_| "main".into());
        checkout_cached_ref(&repo_dir, &ref_name)?;
        return Ok(RepoSyncEvent {
            action: "checkout".into(),
            path: repo_dir,
            ref_name,
        });
    }
    Ok(RepoSyncEvent {
        action: "cached".into(),
        path: repo_dir,
        ref_name: current_ref,
    })
}

fn checkout_cached_ref(repo_dir: &Path, ref_name: &str) -> Result<(), RepoError> {
    let tag_ref = format!("refs/tags/{ref_name}");
    let tag_exists = run_git(
        [
            OsStr::new("-C"),
            repo_dir.as_os_str(),
            OsStr::new("rev-parse"),
            OsStr::new("--verify"),
            OsStr::new(&tag_ref),
        ],
        None,
    )
    .is_ok();

    if tag_exists {
        run_git(
            [
                OsStr::new("-C"),
                repo_dir.as_os_str(),
                OsStr::new("checkout"),
                OsStr::new("--detach"),
                OsStr::new(&tag_ref),
            ],
            None,
        )?;
    } else {
        run_git(
            [
                OsStr::new("-C"),
                repo_dir.as_os_str(),
                OsStr::new("checkout"),
                OsStr::new(ref_name),
            ],
            None,
        )?;
    }
    Ok(())
}

fn current_cached_ref(repo_dir: &Path) -> Option<String> {
    let head = run_git(
        [
            OsStr::new("-C"),
            repo_dir.as_os_str(),
            OsStr::new("symbolic-ref"),
            OsStr::new("--short"),
            OsStr::new("HEAD"),
        ],
        None,
    )
    .ok()?;
    let branch = head.trim();
    if !branch.is_empty() {
        return Some(branch.to_string());
    }

    run_git(
        [
            OsStr::new("-C"),
            repo_dir.as_os_str(),
            OsStr::new("describe"),
            OsStr::new("--tags"),
            OsStr::new("--exact-match"),
        ],
        None,
    )
    .ok()
    .map(|value| value.trim().to_string())
}

fn ensure_cached_repo_valid(repo_dir: &Path) -> Result<(), RepoError> {
    if is_repo_root(repo_dir) {
        return Ok(());
    }
    Err(RepoError::Unavailable(format!(
        "cached repo at {} is incomplete",
        repo_dir.display()
    )))
}

fn cache_is_stale(repo_dir: &Path) -> Result<bool, RepoError> {
    let git_dir = repo_dir.join(".git");
    let metadata = fs::metadata(&git_dir)
        .or_else(|_| fs::metadata(repo_dir))
        .map_err(|error| {
            RepoError::Unavailable(format!(
                "failed to inspect cached repo {}: {error}",
                repo_dir.display()
            ))
        })?;
    let modified = metadata.modified().map_err(|error| {
        RepoError::Unavailable(format!(
            "failed to read cached repo timestamp {}: {error}",
            repo_dir.display()
        ))
    })?;
    let age = SystemTime::now()
        .duration_since(modified)
        .unwrap_or(Duration::ZERO);
    Ok(age >= CACHE_STALE_AFTER)
}

fn select_remote_ref(repo_url: &str, desired_ref: &str) -> Result<String, RepoError> {
    let output = run_git(
        [
            OsStr::new("ls-remote"),
            OsStr::new("--tags"),
            OsStr::new("--heads"),
            OsStr::new(repo_url),
            OsStr::new(desired_ref),
        ],
        None,
    )?;
    if output.trim().is_empty() {
        return Ok("main".into());
    }
    Ok(desired_ref.to_string())
}

fn is_cloudshell() -> bool {
    // AWS_CLOUDSHELL_HOME is the definitive env var (set to /home/cloudshell-user)
    std::env::var_os("AWS_CLOUDSHELL_HOME").is_some()
        || std::env::var("AWS_EXECUTION_ENV")
            .map(|v| v.contains("CloudShell"))
            .unwrap_or(false)
        || std::env::var("USER")
            .map(|u| u == "cloudshell-user")
            .unwrap_or(false)
}

fn cache_repo_dir() -> Result<PathBuf, RepoError> {
    if is_cloudshell() {
        return Ok(PathBuf::from("/tmp/loki-installer/repo"));
    }
    Ok(data_home_dir()?.join("loki-installer").join("repo"))
}

fn data_home_dir() -> Result<PathBuf, RepoError> {
    if let Some(path) = std::env::var_os("XDG_DATA_HOME") {
        return Ok(PathBuf::from(path));
    }

    let home = std::env::var_os("HOME").ok_or(RepoError::DataDirUnavailable)?;
    Ok(PathBuf::from(home).join(".local").join("share"))
}

fn repo_url() -> String {
    std::env::var("LOKI_INSTALLER_REPO_URL").unwrap_or_else(|_| DEFAULT_REPO_URL.into())
}

fn desired_repo_ref() -> String {
    format!("v{}", env!("CARGO_PKG_VERSION"))
}

fn run_git<I, S>(args: I, current_dir: Option<&Path>) -> Result<String, RepoError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut command = Command::new("git");
    command.args(args);
    if let Some(dir) = current_dir {
        command.current_dir(dir);
    }
    let output = command
        .output()
        .map_err(|error| RepoError::Git(format!("failed to spawn git: {error}")))?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).trim().to_string());
    }
    Err(RepoError::Git(
        String::from_utf8_lossy(&output.stderr).trim().to_string(),
    ))
}

#[cfg(test)]
mod tests {
    use super::{detect_repo_root_from, is_repo_root, resolve_repo_root, run_git};
    use std::fs;
    use std::path::{Path, PathBuf};
    use uuid::Uuid;

    struct TestDir {
        path: PathBuf,
    }

    impl TestDir {
        fn new(prefix: &str) -> Self {
            let path = std::env::temp_dir().join(format!("{prefix}-{}", Uuid::new_v4()));
            fs::create_dir_all(&path).expect("create temp dir");
            Self { path }
        }

        fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn detects_repo_root_from_marker_files() {
        let temp = TestDir::new("repo-detect");
        let repo = temp.path().join("loki-agent");
        fs::create_dir_all(repo.join("packs")).expect("packs");
        fs::create_dir_all(repo.join("profiles")).expect("profiles");
        fs::create_dir_all(repo.join("methods")).expect("methods");
        fs::create_dir_all(repo.join("deploy")).expect("deploy");
        fs::write(repo.join("install.sh"), "#!/usr/bin/env bash\n").expect("install.sh");
        let nested = repo.join("tools").join("loki-installer");
        fs::create_dir_all(&nested).expect("nested");

        let detected = detect_repo_root_from(&nested).expect("detect repo");
        assert_eq!(detected, repo);
        assert!(is_repo_root(&detected));
    }

    #[test]
    fn clones_cached_repo_when_markers_absent() {
        let temp = TestDir::new("repo-clone");
        let origin = temp.path().join("origin.git");
        let source = temp.path().join("source");
        let outside = temp.path().join("outside");
        let data_home = temp.path().join("xdg-data");

        fs::create_dir_all(&outside).expect("outside");
        fs::create_dir_all(&data_home).expect("xdg");

        run_git(
            ["init", "--bare", origin.to_str().expect("origin path")],
            None,
        )
        .expect("init bare");
        run_git(["init", source.to_str().expect("source path")], None).expect("init source");
        fs::create_dir_all(source.join("packs")).expect("packs");
        fs::create_dir_all(source.join("profiles")).expect("profiles");
        fs::create_dir_all(source.join("methods")).expect("methods");
        fs::create_dir_all(source.join("deploy")).expect("deploy");
        fs::write(source.join("install.sh"), "#!/usr/bin/env bash\n").expect("install.sh");
        fs::write(source.join("packs/.gitkeep"), "").expect("packs keep");
        fs::write(source.join("profiles/.gitkeep"), "").expect("profiles keep");
        fs::write(source.join("methods/.gitkeep"), "").expect("methods keep");
        fs::write(source.join("deploy/.gitkeep"), "").expect("deploy keep");
        run_git(
            [
                "-C",
                source.to_str().expect("source"),
                "config",
                "user.email",
                "test@example.com",
            ],
            None,
        )
        .expect("git email");
        run_git(
            [
                "-C",
                source.to_str().expect("source"),
                "config",
                "user.name",
                "Test User",
            ],
            None,
        )
        .expect("git name");
        run_git(["-C", source.to_str().expect("source"), "add", "."], None).expect("git add");
        run_git(
            [
                "-C",
                source.to_str().expect("source"),
                "commit",
                "-m",
                "init",
            ],
            None,
        )
        .expect("commit");
        run_git(
            [
                "-C",
                source.to_str().expect("source"),
                "branch",
                "-M",
                "main",
            ],
            None,
        )
        .expect("main");
        run_git(
            [
                "-C",
                source.to_str().expect("source"),
                "remote",
                "add",
                "origin",
                origin.to_str().expect("origin"),
            ],
            None,
        )
        .expect("remote add");
        run_git(
            [
                "-C",
                source.to_str().expect("source"),
                "push",
                "-u",
                "origin",
                "main",
            ],
            None,
        )
        .expect("push");
        run_git(
            [
                "--git-dir",
                origin.to_str().expect("origin"),
                "symbolic-ref",
                "HEAD",
                "refs/heads/main",
            ],
            None,
        )
        .expect("set bare head");

        let old_xdg = std::env::var_os("XDG_DATA_HOME");
        let old_repo_url = std::env::var_os("LOKI_INSTALLER_REPO_URL");
        let old_cwd = std::env::current_dir().expect("cwd");
        unsafe {
            std::env::set_var("XDG_DATA_HOME", &data_home);
            std::env::set_var("LOKI_INSTALLER_REPO_URL", origin.as_os_str());
        }
        std::env::set_current_dir(&outside).expect("chdir");

        let resolved = resolve_repo_root(None).expect("resolve repo");

        std::env::set_current_dir(old_cwd).expect("restore cwd");
        match old_xdg {
            Some(value) => unsafe { std::env::set_var("XDG_DATA_HOME", value) },
            None => unsafe { std::env::remove_var("XDG_DATA_HOME") },
        }
        match old_repo_url {
            Some(value) => unsafe { std::env::set_var("LOKI_INSTALLER_REPO_URL", value) },
            None => unsafe { std::env::remove_var("LOKI_INSTALLER_REPO_URL") },
        }

        let event = resolved.sync_event.expect("sync event");
        assert_eq!(event.action, "clone");
        assert_eq!(event.ref_name, "main");
        assert!(is_repo_root(resolved.root.as_ref().expect("root")));
    }

    #[test]
    fn repo_path_override_wins() {
        let temp = TestDir::new("repo-override");
        let repo = temp.path().join("fixture-repo");
        fs::create_dir_all(repo.join("packs")).expect("packs");
        fs::create_dir_all(repo.join("profiles")).expect("profiles");
        fs::create_dir_all(repo.join("methods")).expect("methods");
        fs::create_dir_all(repo.join("deploy")).expect("deploy");
        fs::write(repo.join("install.sh"), "#!/usr/bin/env bash\n").expect("install.sh");

        let resolved = resolve_repo_root(Some(&repo)).expect("resolve override");
        assert_eq!(resolved.root.as_deref(), Some(repo.as_path()));
        assert!(resolved.sync_event.is_none());
    }
}
