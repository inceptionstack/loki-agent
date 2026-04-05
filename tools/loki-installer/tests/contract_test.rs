use loki_installer::core::{
    DeployMethodId, InstallMode, InstallPlan, InstallRequest, InstallerEngine, Planner,
};
use std::collections::BTreeMap;

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

#[test]
fn install_request_roundtrip_and_validation() {
    let request = sample_request();
    request.validate_contract().expect("valid request");

    let raw = serde_json::to_string_pretty(&request).expect("serialize request");
    let decoded: InstallRequest = serde_json::from_str(&raw).expect("deserialize request");

    assert_eq!(decoded, request);
}

#[tokio::test]
async fn install_plan_roundtrip_and_validation() {
    let planner = Planner::discover().expect("planner discovery");
    let plan = planner
        .build_plan(sample_request())
        .await
        .expect("build plan");
    plan.validate_contract().expect("valid plan");

    let raw = serde_json::to_string_pretty(&plan).expect("serialize plan");
    let decoded: InstallPlan = serde_json::from_str(&raw).expect("deserialize plan");

    assert_eq!(decoded, plan);
}

#[test]
fn invalid_request_is_rejected() {
    let mut request = sample_request();
    request.pack.clear();

    assert!(request.validate_contract().is_err());
}
