use loki_installer::core::{
    DeployMethodId, InstallMode, InstallPhase, InstallRequest, InstallerEngine, Planner,
    create_session, load_latest_session, load_session, persist_session,
};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
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
    let old_path = std::env::var_os("PATH");
    unsafe {
        std::env::set_var("HOME", &tmp);
    }
    let fake_bin = install_fake_aws(&tmp);
    let existing_path = old_path
        .as_ref()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default();
    unsafe {
        std::env::set_var("PATH", format!("{}:{existing_path}", fake_bin.display()));
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
    match old_path {
        Some(value) => unsafe { std::env::set_var("PATH", value) },
        None => unsafe { std::env::remove_var("PATH") },
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

fn install_fake_aws(root: &PathBuf) -> PathBuf {
    let bin_dir = root.join("bin");
    fs::create_dir_all(&bin_dir).expect("create fake bin dir");
    let aws_path = bin_dir.join("aws");
    fs::write(
        &aws_path,
        r#"#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  *"sts get-caller-identity --output json --region us-east-1"*)
    printf '%s\n' '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test","UserId":"AIDATEST"}'
    ;;
  *"cloudformation update-stack"*)
    printf '%s\n' '{"StackId":"arn:aws:cloudformation:us-east-1:123456789012:stack/loki-openclaw/test"}'
    ;;
  *"cloudformation wait stack-update-complete"*)
    exit 0
    ;;
  *"cloudformation describe-stack-events"*)
    printf '%s\n' '{"StackEvents":[{"EventId":"1","LogicalResourceId":"loki-openclaw","ResourceType":"AWS::CloudFormation::Stack","ResourceStatus":"UPDATE_COMPLETE","ResourceStatusReason":"completed"}]}'
    ;;
  *"cloudformation describe-stacks"*)
    printf '%s\n' '{"Stacks":[{"StackStatus":"CREATE_COMPLETE","Outputs":[{"OutputKey":"InstanceId","OutputValue":"i-123"},{"OutputKey":"PublicIp","OutputValue":"1.2.3.4"}]}]}'
    ;;
  *)
    printf 'unexpected aws invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
"#,
    )
    .expect("write fake aws");
    let mut permissions = fs::metadata(&aws_path)
        .expect("fake aws metadata")
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&aws_path, permissions).expect("chmod fake aws");
    bin_dir
}
