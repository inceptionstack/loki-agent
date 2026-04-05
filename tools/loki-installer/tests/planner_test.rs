use loki_installer::core::{DeployMethodId, InstallMode, InstallRequest, InstallerEngine, Planner};
use std::collections::BTreeMap;

fn cfn_request() -> InstallRequest {
    InstallRequest {
        engine: InstallerEngine::V2,
        mode: InstallMode::NonInteractive,
        pack: "openclaw".into(),
        profile: Some("builder".into()),
        method: Some(DeployMethodId::Cfn),
        region: Some("us-east-1".into()),
        stack_name: None,
        auto_yes: true,
        json_output: false,
        resume_session_id: None,
        extra_options: BTreeMap::from([("capabilities".into(), "CAPABILITY_NAMED_IAM".into())]),
    }
}

#[tokio::test]
async fn planner_generates_resolved_plan_from_request_and_manifests() {
    let planner = Planner::discover().expect("planner discovery");
    let plan = planner.build_plan(cfn_request()).await.expect("build plan");

    assert_eq!(plan.resolved_pack.id, "openclaw");
    assert_eq!(plan.resolved_profile.id, "builder");
    assert_eq!(plan.resolved_method.id, DeployMethodId::Cfn);
    assert_eq!(plan.resolved_region, "us-east-1");
    assert_eq!(plan.resolved_stack_name.as_deref(), Some("loki-openclaw"));
    assert_eq!(
        plan.adapter_options.get("capabilities").map(String::as_str),
        Some("CAPABILITY_NAMED_IAM")
    );
}

#[tokio::test]
async fn planner_applies_method_defaults_and_omits_stack_name_for_terraform() {
    let planner = Planner::discover().expect("planner discovery");
    let mut request = cfn_request();
    request.pack = "hermes".into();
    request.method = Some(DeployMethodId::Terraform);
    request.stack_name = None;
    request.extra_options = BTreeMap::new();

    let plan = planner.build_plan(request).await.expect("build plan");

    assert_eq!(plan.resolved_method.id, DeployMethodId::Terraform);
    assert_eq!(plan.resolved_stack_name, None);
    assert_eq!(
        plan.adapter_options.get("workspace").map(String::as_str),
        Some("default")
    );
}

#[tokio::test]
async fn planner_rejects_unknown_extra_options() {
    let planner = Planner::discover().expect("planner discovery");
    let mut request = cfn_request();
    request
        .extra_options
        .insert("unknown".into(), "value".into());

    let error = planner
        .build_plan(request)
        .await
        .expect_err("unknown option");
    assert!(error.to_string().contains("invalid option"));
}
