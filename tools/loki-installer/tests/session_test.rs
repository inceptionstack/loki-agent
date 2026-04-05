use loki_installer::core::{
    DeployMethodId, InstallMode, InstallPhase, InstallRequest, InstallerEngine, Planner,
    create_session, load_latest_session, load_session, persist_session,
};
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn sample_request() -> InstallRequest {
    InstallRequest {
        engine: InstallerEngine::V2,
        mode: InstallMode::NonInteractive,
        pack: "openclaw".into(),
        profile: Some("builder".into()),
        method: Some(DeployMethodId::Cfn),
        region: Some("us-east-1".into()),
        stack_name: Some("loki-openclaw".into()),
        auto_yes: true,
        json_output: false,
        resume_session_id: None,
        extra_options: BTreeMap::from([("capabilities".into(), "CAPABILITY_NAMED_IAM".into())]),
    }
}

#[tokio::test]
async fn session_persistence_write_read_and_resume() {
    let tmp = unique_temp_home();
    fs::create_dir_all(&tmp).expect("create temp home");
    let old_home = std::env::var_os("HOME");
    unsafe {
        std::env::set_var("HOME", &tmp);
    }

    let planner = Planner::discover().expect("planner discovery");
    let plan = planner
        .build_plan(sample_request())
        .await
        .expect("build plan");
    let session = create_session(plan.request.clone(), Some(plan));
    persist_session(&session).expect("persist session");

    let loaded = load_session(&session.session_id).expect("load session by id");
    assert_eq!(loaded.session_id, session.session_id);

    let latest = load_latest_session().expect("load latest session");
    assert_eq!(latest.session_id, session.session_id);

    let mut resumable = loaded;
    planner
        .resume_install(&mut resumable)
        .await
        .expect("resume install");
    assert_eq!(resumable.phase, InstallPhase::PostInstall);
    assert!(resumable.artifacts.contains_key("stack_status"));

    match old_home {
        Some(value) => unsafe { std::env::set_var("HOME", value) },
        None => unsafe { std::env::remove_var("HOME") },
    }
    fs::remove_dir_all(tmp).expect("cleanup temp home");
}

fn unique_temp_home() -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock")
        .as_nanos();
    std::env::temp_dir().join(format!("loki-installer-session-test-{suffix}"))
}
