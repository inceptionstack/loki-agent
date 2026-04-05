//! Terraform deployment adapter.

use crate::core::{
    AdapterError, AdapterPlan, AdapterValidationError, ApplyResult, DeployAction, DeployAdapter,
    DeployMethodId, DeployStatus, DeployStep, InstallEvent, InstallEventSink, InstallPhase,
    InstallPlan, InstallRequest, InstallSession, MethodManifest, PackManifest, PlanWarning,
    PostInstallStep, PrerequisiteCheck, PrerequisiteKind, ProfileManifest, UninstallResult,
    update_session_phase,
};
use std::collections::BTreeMap;
use tokio::time::{Duration, sleep};

pub struct TerraformAdapter;

#[async_trait::async_trait]
impl DeployAdapter for TerraformAdapter {
    fn method_id(&self) -> DeployMethodId {
        DeployMethodId::Terraform
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
        adapter_options.insert("working_dir".into(), "deploy/terraform".into());
        adapter_options.insert("pack".into(), pack.id.clone());
        adapter_options.insert("profile".into(), profile.id.clone());
        if let Some(region) = &request.region {
            adapter_options.insert("region".into(), region.clone());
        }

        Ok(AdapterPlan {
            prerequisites: vec![PrerequisiteCheck {
                id: "terraform_cli".into(),
                display_name: "Terraform CLI available".into(),
                kind: PrerequisiteKind::MethodToolingPresent,
                required: true,
                remediation: Some("Install terraform and re-run the installer.".into()),
            }],
            deploy_steps: vec![
                DeployStep {
                    id: "terraform-init".into(),
                    phase: InstallPhase::PrepareDeployment,
                    display_name: "Initialize Terraform".into(),
                    action: DeployAction::RunCommand {
                        program: "terraform".into(),
                        args: vec!["init".into()],
                    },
                },
                DeployStep {
                    id: "terraform-plan".into(),
                    phase: InstallPhase::PlanDeployment,
                    display_name: "Plan Terraform changes".into(),
                    action: DeployAction::RunCommand {
                        program: "terraform".into(),
                        args: vec!["plan".into()],
                    },
                },
                DeployStep {
                    id: "terraform-apply".into(),
                    phase: InstallPhase::ApplyDeployment,
                    display_name: "Apply Terraform changes".into(),
                    action: DeployAction::RunCommand {
                        program: "terraform".into(),
                        args: vec!["apply".into(), "-auto-approve".into()],
                    },
                },
                DeployStep {
                    id: "terraform-health".into(),
                    phase: InstallPhase::PostInstall,
                    display_name: "Check deployment health".into(),
                    action: DeployAction::VerifyInstanceHealth,
                },
            ],
            adapter_options,
            warnings: vec![PlanWarning {
                code: "terraform_async_bootstrap".into(),
                message: "Terraform reports success before EC2 bootstrap finishes; verify health afterward.".into(),
            }],
            post_install_steps: vec![PostInstallStep {
                id: "terraform-output".into(),
                display_name: "Inspect Terraform outputs".into(),
                instruction: "terraform -chdir=deploy/terraform output".into(),
            }],
        })
    }

    async fn apply(
        &self,
        plan: &InstallPlan,
        session: &mut InstallSession,
        event_sink: &mut dyn InstallEventSink,
    ) -> Result<ApplyResult, AdapterError> {
        run_stubbed_apply(plan, session, event_sink).await
    }

    async fn resume(
        &self,
        session: &mut InstallSession,
        event_sink: &mut dyn InstallEventSink,
    ) -> Result<ApplyResult, AdapterError> {
        let plan = session.plan.clone().ok_or(AdapterError::NotResumable)?;
        run_stubbed_apply(&plan, session, event_sink).await
    }

    async fn uninstall(
        &self,
        session: &InstallSession,
        event_sink: &mut dyn InstallEventSink,
    ) -> Result<UninstallResult, AdapterError> {
        event_sink
            .emit(InstallEvent::LogLine {
                message: format!("would terraform destroy for pack {}", session.request.pack),
            })
            .await;
        Ok(UninstallResult {
            removed_artifacts: BTreeMap::from([("state".into(), "terraform".into())]),
            warnings: vec![PlanWarning {
                code: "stubbed_uninstall".into(),
                message: "Terraform uninstall is currently a stub.".into(),
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
            method: DeployMethodId::Terraform,
            region: plan
                .map(|plan| plan.resolved_region.clone())
                .or_else(|| session.request.region.clone()),
            stack_name: plan
                .and_then(|plan| plan.resolved_stack_name.clone())
                .or_else(|| session.request.stack_name.clone()),
            stack_status: Some("terraform_applied".into()),
            instance_health: session.artifacts.get("instance_health").cloned(),
            last_updated_at: session.updated_at,
        })
    }
}

async fn run_stubbed_apply(
    plan: &InstallPlan,
    session: &mut InstallSession,
    event_sink: &mut dyn InstallEventSink,
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
    artifacts.insert("terraform_state".into(), "applied".into());
    artifacts.insert("instance_health".into(), "healthy".into());

    Ok(ApplyResult {
        final_phase: InstallPhase::PostInstall,
        artifacts,
        post_install_steps: plan.post_install_steps.clone(),
    })
}
