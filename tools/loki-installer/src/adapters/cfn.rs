//! CloudFormation deployment adapter.

use crate::core::{
    AdapterError, AdapterPlan, AdapterValidationError, ApplyResult, DeployAction, DeployAdapter,
    DeployMethodId, DeployStatus, DeployStep, InstallEvent, InstallEventSink, InstallPhase,
    InstallPlan, InstallRequest, InstallSession, MethodManifest, PackManifest, PlanWarning,
    PostInstallStep, PrerequisiteCheck, PrerequisiteKind, ProfileManifest, UninstallResult,
    update_session_phase,
};
use std::collections::BTreeMap;
use tokio::time::{Duration, sleep};

pub struct CfnAdapter;

#[async_trait::async_trait]
impl DeployAdapter for CfnAdapter {
    fn method_id(&self) -> DeployMethodId {
        DeployMethodId::Cfn
    }

    fn validate_request(
        &self,
        _request: &InstallRequest,
        _pack: &PackManifest,
        _profile: Option<&ProfileManifest>,
        _method: &MethodManifest,
    ) -> Result<(), AdapterValidationError> {
        Ok(())
    }

    async fn build_plan(
        &self,
        request: &InstallRequest,
        pack: &PackManifest,
        profile: &ProfileManifest,
        _method: &MethodManifest,
    ) -> Result<AdapterPlan, AdapterError> {
        let mut adapter_options = BTreeMap::new();
        adapter_options.insert(
            "template_path".into(),
            "deploy/cloudformation/template.yaml".into(),
        );
        adapter_options.insert("pack".into(), pack.id.clone());
        adapter_options.insert("profile".into(), profile.id.clone());
        if let Some(region) = &request.region {
            adapter_options.insert("region".into(), region.clone());
        }

        Ok(AdapterPlan {
            prerequisites: vec![
                PrerequisiteCheck {
                    id: "aws_cli".into(),
                    display_name: "AWS CLI available".into(),
                    kind: PrerequisiteKind::AwsCliPresent,
                    required: true,
                    remediation: Some("Install aws and re-run the installer.".into()),
                },
                PrerequisiteCheck {
                    id: "cloudformation_template".into(),
                    display_name: "CloudFormation template present".into(),
                    kind: PrerequisiteKind::BinaryDownloadable,
                    required: true,
                    remediation: Some("Ensure deploy/cloudformation/template.yaml exists.".into()),
                },
            ],
            deploy_steps: vec![
                DeployStep {
                    id: "validate-environment".into(),
                    phase: InstallPhase::ValidateEnvironment,
                    display_name: "Validate environment".into(),
                    action: DeployAction::RunCommand {
                        program: "aws".into(),
                        args: vec!["--version".into()],
                    },
                },
                DeployStep {
                    id: "create-stack".into(),
                    phase: InstallPhase::ApplyDeployment,
                    display_name: "Create or update CloudFormation stack".into(),
                    action: DeployAction::CreateStack,
                },
                DeployStep {
                    id: "wait-stack".into(),
                    phase: InstallPhase::WaitForResources,
                    display_name: "Wait for stack completion".into(),
                    action: DeployAction::WaitForStack,
                },
                DeployStep {
                    id: "emit-post-install".into(),
                    phase: InstallPhase::PostInstall,
                    display_name: "Emit post-install instructions".into(),
                    action: DeployAction::EmitInstructions,
                },
            ],
            adapter_options,
            warnings: Vec::new(),
            post_install_steps: vec![PostInstallStep {
                id: "cfn_outputs".into(),
                display_name: "Inspect stack outputs".into(),
                instruction: format!(
                    "aws cloudformation describe-stacks --stack-name {}",
                    request
                        .stack_name
                        .clone()
                        .unwrap_or_else(|| format!("loki-{}", pack.id))
                ),
            }],
        })
    }

    async fn apply(
        &self,
        plan: &InstallPlan,
        session: &mut InstallSession,
        event_sink: &mut dyn InstallEventSink,
    ) -> Result<ApplyResult, AdapterError> {
        run_stubbed_apply(plan, session, event_sink, "CREATE_COMPLETE").await
    }

    async fn resume(
        &self,
        session: &mut InstallSession,
        event_sink: &mut dyn InstallEventSink,
    ) -> Result<ApplyResult, AdapterError> {
        let plan = session.plan.clone().ok_or(AdapterError::NotResumable)?;
        run_stubbed_apply(&plan, session, event_sink, "CREATE_COMPLETE").await
    }

    async fn uninstall(
        &self,
        session: &InstallSession,
        event_sink: &mut dyn InstallEventSink,
    ) -> Result<UninstallResult, AdapterError> {
        event_sink
            .emit(InstallEvent::LogLine {
                message: format!("would delete stack {:?}", session.request.stack_name),
            })
            .await;
        Ok(UninstallResult {
            removed_artifacts: BTreeMap::from([(
                "stack_name".into(),
                session.request.stack_name.clone().unwrap_or_default(),
            )]),
            warnings: vec![PlanWarning {
                code: "stubbed_uninstall".into(),
                message: "CloudFormation uninstall is currently a stub.".into(),
            }],
        })
    }

    async fn status(&self, session: &InstallSession) -> Result<DeployStatus, AdapterError> {
        let plan = session.plan.as_ref();
        Ok(DeployStatus {
            deployed: session.phase == InstallPhase::PostInstall,
            pack: session.request.pack.clone(),
            profile: plan
                .map(|plan| plan.resolved_profile.id.clone())
                .or_else(|| session.request.profile.clone())
                .unwrap_or_default(),
            method: DeployMethodId::Cfn,
            region: plan
                .map(|plan| plan.resolved_region.clone())
                .or_else(|| session.request.region.clone()),
            stack_name: plan
                .and_then(|plan| plan.resolved_stack_name.clone())
                .or_else(|| session.request.stack_name.clone()),
            stack_status: Some(
                session
                    .artifacts
                    .get("stack_status")
                    .cloned()
                    .unwrap_or_else(|| "UNKNOWN".into()),
            ),
            instance_health: session.artifacts.get("instance_health").cloned(),
            last_updated_at: session.updated_at,
        })
    }
}

async fn run_stubbed_apply(
    plan: &InstallPlan,
    session: &mut InstallSession,
    event_sink: &mut dyn InstallEventSink,
    stack_status: &str,
) -> Result<ApplyResult, AdapterError> {
    let mut artifacts = BTreeMap::new();
    for step in &plan.deploy_steps {
        update_session_phase(session, step.phase);
        event_sink
            .emit(InstallEvent::PhaseStarted {
                phase: step.phase,
                message: step.display_name.clone(),
            })
            .await;
        event_sink
            .emit(InstallEvent::StepStarted {
                step_id: step.id.clone(),
                message: step.display_name.clone(),
            })
            .await;
        sleep(Duration::from_millis(50)).await;
        event_sink
            .emit(InstallEvent::StepFinished {
                step_id: step.id.clone(),
                message: "completed".into(),
            })
            .await;
    }

    update_session_phase(session, InstallPhase::PostInstall);
    artifacts.insert(
        "stack_name".into(),
        plan.resolved_stack_name
            .clone()
            .unwrap_or_else(|| format!("loki-{}", plan.resolved_pack.id)),
    );
    artifacts.insert("stack_status".into(), stack_status.into());
    artifacts.insert("instance_health".into(), "healthy".into());

    Ok(ApplyResult {
        final_phase: InstallPhase::PostInstall,
        artifacts,
        post_install_steps: plan.post_install_steps.clone(),
    })
}
