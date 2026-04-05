//! Terraform deployment adapter.

use crate::adapters::support::{CommandOutput, CommandSpec, resolve_repo_path, run_command};
use crate::core::{
    AdapterError, AdapterPlan, AdapterValidationError, ApplyResult, DeployAction, DeployAdapter,
    DeployMethodId, DeployStatus, DeployStep, InstallEvent, InstallEventSink, InstallPhase,
    InstallPlan, InstallRequest, InstallSession, MethodManifest, PackManifest, PlanWarning,
    PostInstallStep, PrerequisiteCheck, PrerequisiteKind, ProfileManifest, UninstallResult,
    update_session_phase,
};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::Path;

pub struct TerraformAdapter;

#[derive(Debug, Clone)]
struct TerraformContext {
    working_dir: String,
    plan_file: String,
    region: String,
    pack: String,
    profile: String,
    environment_name: String,
    tf_vars: Vec<(String, String)>,
}

#[derive(Debug, Deserialize)]
struct TerraformOutputValue {
    value: serde_json::Value,
}

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
                        args: vec!["init".into(), "-input=false".into()],
                    },
                },
                DeployStep {
                    id: "terraform-plan".into(),
                    phase: InstallPhase::PlanDeployment,
                    display_name: "Plan Terraform changes".into(),
                    action: DeployAction::RunCommand {
                        program: "terraform".into(),
                        args: vec!["plan".into(), "-input=false".into()],
                    },
                },
                DeployStep {
                    id: "terraform-apply".into(),
                    phase: InstallPhase::ApplyDeployment,
                    display_name: "Apply Terraform changes".into(),
                    action: DeployAction::RunCommand {
                        program: "terraform".into(),
                        args: vec![
                            "apply".into(),
                            "-input=false".into(),
                            "-auto-approve".into(),
                        ],
                    },
                },
                DeployStep {
                    id: "terraform-health".into(),
                    phase: InstallPhase::PostInstall,
                    display_name: "Capture Terraform outputs".into(),
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
        apply_terraform(plan, session, event_sink).await
    }

    async fn resume(
        &self,
        session: &mut InstallSession,
        event_sink: &mut dyn InstallEventSink,
    ) -> Result<ApplyResult, AdapterError> {
        let plan = session.plan.clone().ok_or(AdapterError::NotResumable)?;
        apply_terraform(&plan, session, event_sink).await
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
            stack_status: session
                .artifacts
                .get("stack_status")
                .cloned()
                .or(Some("terraform_applied".into())),
            instance_health: session.artifacts.get("instance_health").cloned(),
            last_updated_at: session.updated_at,
        })
    }
}

impl TerraformContext {
    fn from_plan(plan: &InstallPlan) -> Result<Self, AdapterError> {
        let working_dir = resolve_repo_path(
            plan.adapter_options
                .get("working_dir")
                .map(String::as_str)
                .unwrap_or("deploy/terraform"),
        )?;
        let environment_name = plan
            .resolved_stack_name
            .clone()
            .unwrap_or_else(|| format!("loki-{}", plan.resolved_pack.id));

        Ok(Self {
            plan_file: Path::new(&working_dir).join("tfplan").display().to_string(),
            working_dir,
            region: plan.resolved_region.clone(),
            pack: plan.resolved_pack.id.clone(),
            profile: plan.resolved_profile.id.clone(),
            environment_name,
            tf_vars: plan
                .adapter_options
                .iter()
                .filter_map(|(key, value)| {
                    adapter_option_to_tf_var(key)
                        .map(|var_name| (var_name.to_string(), value.clone()))
                })
                .collect(),
        })
    }
}

async fn apply_terraform(
    plan: &InstallPlan,
    session: &mut InstallSession,
    event_sink: &mut dyn InstallEventSink,
) -> Result<ApplyResult, AdapterError> {
    let context = TerraformContext::from_plan(plan)?;
    if !Path::new(&context.working_dir).exists() {
        return Err(AdapterError::Message(format!(
            "Terraform working directory not found at {} — verify the repo checkout includes deploy/terraform",
            context.working_dir
        )));
    }

    let mut artifacts = BTreeMap::new();

    for step in &plan.deploy_steps {
        emit_step_started(session, event_sink, step).await;

        match step.id.as_str() {
            "terraform-init" => {
                let output =
                    run_command(&build_terraform_init_command(&context.working_dir)).await?;
                ensure_terraform_success(
                    &output,
                    "Terraform init failed — run terraform init manually in deploy/terraform for details",
                )?;
                record_command_artifact(
                    "terraform_init_output",
                    output,
                    &mut artifacts,
                    event_sink,
                )
                .await;
            }
            "terraform-plan" => {
                let output = run_command(&build_terraform_plan_command(
                    &context.working_dir,
                    &context.plan_file,
                    &context.region,
                    &context.pack,
                    &context.profile,
                    &context.environment_name,
                    &context.tf_vars,
                ))
                .await?;
                ensure_terraform_success(
                    &output,
                    "Terraform plan failed — fix the reported variable or provider issue and retry",
                )?;
                record_command_artifact(
                    "terraform_plan_output",
                    output,
                    &mut artifacts,
                    event_sink,
                )
                .await;
            }
            "terraform-apply" => {
                let output = run_command(&build_terraform_apply_command(
                    &context.working_dir,
                    &context.plan_file,
                ))
                .await?;
                ensure_terraform_success(
                    &output,
                    "Terraform apply failed — inspect the Terraform output for the rejected AWS resource or permission",
                )?;
                record_command_artifact(
                    "terraform_apply_output",
                    output,
                    &mut artifacts,
                    event_sink,
                )
                .await;
            }
            "terraform-health" => {
                let output =
                    run_command(&build_terraform_output_command(&context.working_dir)).await?;
                ensure_terraform_success(
                    &output,
                    "Terraform output failed — run terraform output -json in deploy/terraform",
                )?;
                for (key, value) in parse_terraform_outputs(&output.stdout)? {
                    artifacts.insert(key.clone(), value.clone());
                    event_sink
                        .emit(InstallEvent::ArtifactRecorded { key, value })
                        .await;
                }
                artifacts.insert("stack_status".into(), "terraform_applied".into());
                artifacts.insert("instance_health".into(), "unknown".into());
            }
            _ => {}
        }

        emit_step_finished(event_sink, step, "completed").await;
    }

    update_session_phase(session, InstallPhase::PostInstall);
    session.artifacts.extend(artifacts.clone());

    Ok(ApplyResult {
        final_phase: InstallPhase::PostInstall,
        artifacts,
        post_install_steps: plan.post_install_steps.clone(),
    })
}

fn build_terraform_init_command(working_dir: &str) -> CommandSpec {
    CommandSpec {
        program: "terraform".into(),
        args: vec![
            format!("-chdir={working_dir}"),
            "init".into(),
            "-input=false".into(),
        ],
        current_dir: None,
    }
}

fn build_terraform_plan_command(
    working_dir: &str,
    plan_file: &str,
    region: &str,
    pack: &str,
    profile: &str,
    environment_name: &str,
    tf_vars: &[(String, String)],
) -> CommandSpec {
    let mut args = vec![
        format!("-chdir={working_dir}"),
        "plan".into(),
        "-input=false".into(),
        format!("-out={plan_file}"),
        format!("-var=aws_region={region}"),
        format!("-var=pack_name={pack}"),
        format!("-var=profile_name={profile}"),
        format!("-var=environment_name={environment_name}"),
    ];
    for (name, value) in tf_vars {
        args.push(format!("-var={name}={value}"));
    }

    CommandSpec {
        program: "terraform".into(),
        args,
        current_dir: None,
    }
}

fn adapter_option_to_tf_var(key: &str) -> Option<&'static str> {
    match key {
        "model" => Some("default_model"),
        "port" => Some("openclaw_gateway_port"),
        "bedrockify_port" => Some("bedrockify_port"),
        "embed_model" => Some("embed_model"),
        "hermes_model" => Some("hermes_model"),
        "haiku_model" => Some("haiku_model"),
        "sandbox_name" => Some("sandbox_name"),
        "telegram_token" => Some("telegram_token"),
        "allowed_chat_ids" => Some("allowed_chat_ids"),
        "working_dir" | "pack" | "profile" | "region" | "workspace" => None,
        _ => None,
    }
}

fn build_terraform_apply_command(working_dir: &str, plan_file: &str) -> CommandSpec {
    CommandSpec {
        program: "terraform".into(),
        args: vec![
            format!("-chdir={working_dir}"),
            "apply".into(),
            "-input=false".into(),
            "-auto-approve".into(),
            plan_file.into(),
        ],
        current_dir: None,
    }
}

fn build_terraform_output_command(working_dir: &str) -> CommandSpec {
    CommandSpec {
        program: "terraform".into(),
        args: vec![
            format!("-chdir={working_dir}"),
            "output".into(),
            "-json".into(),
        ],
        current_dir: None,
    }
}

fn parse_terraform_outputs(raw: &str) -> Result<BTreeMap<String, String>, AdapterError> {
    let parsed: BTreeMap<String, TerraformOutputValue> =
        serde_json::from_str(raw).map_err(|source| {
            AdapterError::Message(format!("Failed to parse terraform output JSON — {source}"))
        })?;

    let mut artifacts = BTreeMap::new();
    artifacts.insert("terraform_output_json".into(), raw.to_string());

    for (key, value) in parsed {
        let text = match value.value {
            serde_json::Value::String(text) => text,
            other => other.to_string(),
        };
        match key.as_str() {
            "instance_id" | "public_ip" | "private_ip" | "vpc_id" | "security_group_id"
            | "role_arn" | "ssm_connect" | "pack_name" | "profile_name" => {
                artifacts.insert(key, text);
            }
            _ => {}
        }
    }

    Ok(artifacts)
}

fn ensure_terraform_success(
    output: &CommandOutput,
    default_message: &str,
) -> Result<(), AdapterError> {
    if output.success() {
        return Ok(());
    }

    let stderr = output.stderr.trim();
    if stderr.contains("No such file or directory") || stderr.contains("command not found") {
        return Err(AdapterError::Message(
            "Terraform CLI not found — install terraform and re-run the installer".into(),
        ));
    }

    if stderr.contains("No valid credential sources found")
        || stderr.contains("failed to refresh cached credentials")
    {
        return Err(AdapterError::Message(
            "AWS credentials not found — run aws configure or export AWS_ACCESS_KEY_ID".into(),
        ));
    }

    let mut message = default_message.to_string();
    if !stderr.is_empty() {
        message.push_str(": ");
        message.push_str(stderr);
    } else if !output.stdout.is_empty() {
        message.push_str(": ");
        message.push_str(output.stdout.trim());
    }
    Err(AdapterError::Message(message))
}

async fn record_command_artifact(
    key: &str,
    output: CommandOutput,
    artifacts: &mut BTreeMap<String, String>,
    event_sink: &mut dyn InstallEventSink,
) {
    let value = if output.stdout.is_empty() {
        output.stderr
    } else {
        output.stdout
    };
    artifacts.insert(key.into(), value.clone());
    event_sink
        .emit(InstallEvent::ArtifactRecorded {
            key: key.into(),
            value,
        })
        .await;
}

async fn emit_step_started(
    session: &mut InstallSession,
    event_sink: &mut dyn InstallEventSink,
    step: &DeployStep,
) {
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
}

async fn emit_step_finished(
    event_sink: &mut dyn InstallEventSink,
    step: &DeployStep,
    message: &str,
) {
    event_sink
        .emit(InstallEvent::StepFinished {
            step_id: step.id.clone(),
            message: message.into(),
        })
        .await;
}

#[cfg(test)]
mod tests {
    use super::{
        adapter_option_to_tf_var, build_terraform_apply_command, build_terraform_init_command,
        build_terraform_plan_command, parse_terraform_outputs,
    };

    #[test]
    fn terraform_init_command_uses_working_dir_and_non_interactive_flags() {
        let command = build_terraform_init_command("/tmp/repo/deploy/terraform");
        assert_eq!(command.program, "terraform");
        assert_eq!(
            command.args,
            vec!["-chdir=/tmp/repo/deploy/terraform", "init", "-input=false",]
        );
    }

    #[test]
    fn terraform_plan_command_includes_outfile_and_tf_vars() {
        let command = build_terraform_plan_command(
            "/tmp/repo/deploy/terraform",
            "/tmp/repo/deploy/terraform/tfplan",
            "us-east-1",
            "openclaw",
            "builder",
            "loki-openclaw",
            &[
                (
                    "default_model".into(),
                    "us.anthropic.claude-opus-4-6-v1".into(),
                ),
                ("openclaw_gateway_port".into(), "3001".into()),
                ("bedrockify_port".into(), "8090".into()),
                (
                    "haiku_model".into(),
                    "us.anthropic.claude-haiku-4-5-20251001-v1:0".into(),
                ),
            ],
        );
        assert_eq!(command.program, "terraform");
        assert!(command.args.contains(&"plan".into()));
        assert!(command.args.contains(&"-input=false".into()));
        assert!(
            command
                .args
                .contains(&"-out=/tmp/repo/deploy/terraform/tfplan".into())
        );
        assert!(command.args.contains(&"-var=aws_region=us-east-1".into()));
        assert!(command.args.contains(&"-var=pack_name=openclaw".into()));
        assert!(command.args.contains(&"-var=profile_name=builder".into()));
        assert!(
            command
                .args
                .contains(&"-var=environment_name=loki-openclaw".into())
        );
        assert!(
            command
                .args
                .contains(&"-var=default_model=us.anthropic.claude-opus-4-6-v1".into())
        );
        assert!(
            command
                .args
                .contains(&"-var=openclaw_gateway_port=3001".into())
        );
        assert!(command.args.contains(&"-var=bedrockify_port=8090".into()));
        assert!(
            command
                .args
                .contains(&"-var=haiku_model=us.anthropic.claude-haiku-4-5-20251001-v1:0".into())
        );
    }

    #[test]
    fn terraform_var_mapping_covers_pack_specific_options() {
        assert_eq!(
            adapter_option_to_tf_var("bedrockify_port"),
            Some("bedrockify_port")
        );
        assert_eq!(adapter_option_to_tf_var("embed_model"), Some("embed_model"));
        assert_eq!(
            adapter_option_to_tf_var("hermes_model"),
            Some("hermes_model")
        );
        assert_eq!(adapter_option_to_tf_var("haiku_model"), Some("haiku_model"));
        assert_eq!(
            adapter_option_to_tf_var("sandbox_name"),
            Some("sandbox_name")
        );
        assert_eq!(
            adapter_option_to_tf_var("telegram_token"),
            Some("telegram_token")
        );
        assert_eq!(
            adapter_option_to_tf_var("allowed_chat_ids"),
            Some("allowed_chat_ids")
        );
        assert_eq!(adapter_option_to_tf_var("workspace"), None);
    }

    #[test]
    fn terraform_apply_command_uses_saved_plan() {
        let command =
            build_terraform_apply_command("/tmp/repo/deploy/terraform", "/tmp/repo/tfplan");
        assert_eq!(command.program, "terraform");
        assert_eq!(
            command.args,
            vec![
                "-chdir=/tmp/repo/deploy/terraform",
                "apply",
                "-input=false",
                "-auto-approve",
                "/tmp/repo/tfplan",
            ]
        );
    }

    #[test]
    fn parse_terraform_outputs_extracts_instance_id_and_public_ip() {
        let artifacts = parse_terraform_outputs(
            r#"{
              "instance_id": {"value": "i-123"},
              "public_ip": {"value": "1.2.3.4"},
              "role_arn": {"value": "arn:aws:iam::123456789012:role/example"}
            }"#,
        )
        .expect("parse terraform outputs");

        assert_eq!(artifacts.get("instance_id"), Some(&"i-123".into()));
        assert_eq!(artifacts.get("public_ip"), Some(&"1.2.3.4".into()));
        assert!(artifacts.get("terraform_output_json").is_some());
    }
}
