//! CloudFormation deployment adapter.

use crate::adapters::support::{
    CommandOutput, CommandSpec, resolve_repo_path, run_command, spawn_child,
};
use crate::core::{
    AdapterError, AdapterPlan, AdapterValidationError, ApplyResult, DeployAction, DeployAdapter,
    DeployMethodId, DeployStatus, DeployStep, InstallEvent, InstallEventSink, InstallPhase,
    InstallPlan, InstallRequest, InstallSession, MethodManifest, PackManifest, PlanWarning,
    PostInstallStep, PrerequisiteCheck, PrerequisiteKind, ProfileManifest, UninstallResult,
    update_session_phase,
};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use tokio::time::{Duration, sleep};

const STACK_EVENT_POLL_INTERVAL: Duration = Duration::from_secs(2);

pub struct CfnAdapter;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StackOperation {
    Create,
    Update,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WaiterKind {
    CreateComplete,
    UpdateComplete,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct StackProgress {
    operation: Option<StackOperation>,
    waiter: WaiterKind,
    wait_required: bool,
}

#[derive(Debug, Deserialize)]
struct DescribeStacksResponse {
    #[serde(rename = "Stacks")]
    stacks: Vec<StackDescription>,
}

#[derive(Debug, Deserialize)]
struct CallerIdentityResponse {
    #[serde(rename = "Account")]
    account: String,
}

#[derive(Debug, Deserialize)]
struct StackDescription {
    #[serde(rename = "StackStatus")]
    stack_status: String,
    #[serde(rename = "Outputs", default)]
    outputs: Vec<StackOutput>,
}

#[derive(Debug, Deserialize)]
struct StackOutput {
    #[serde(rename = "OutputKey")]
    output_key: String,
    #[serde(rename = "OutputValue")]
    output_value: String,
}

#[derive(Debug, Deserialize)]
struct DescribeStackEventsResponse {
    #[serde(rename = "StackEvents", default)]
    stack_events: Vec<StackEvent>,
}

#[derive(Debug, Deserialize)]
struct StackEvent {
    #[serde(rename = "EventId")]
    event_id: String,
    #[serde(rename = "LogicalResourceId")]
    logical_resource_id: String,
    #[serde(rename = "ResourceType")]
    resource_type: String,
    #[serde(rename = "ResourceStatus")]
    resource_status: String,
    #[serde(rename = "ResourceStatusReason")]
    resource_status_reason: Option<String>,
}

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
                        args: vec![
                            "sts".into(),
                            "get-caller-identity".into(),
                            "--output".into(),
                            "json".into(),
                        ],
                    },
                },
                DeployStep {
                    id: "stage-template".into(),
                    phase: InstallPhase::PrepareDeployment,
                    display_name: "Upload CloudFormation template to S3".into(),
                    action: DeployAction::RunCommand {
                        program: "aws".into(),
                        args: vec!["s3".into(), "cp".into()],
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
        apply_cloudformation(plan, session, event_sink).await
    }

    async fn resume(
        &self,
        session: &mut InstallSession,
        event_sink: &mut dyn InstallEventSink,
    ) -> Result<ApplyResult, AdapterError> {
        let plan = session.plan.clone().ok_or(AdapterError::NotResumable)?;
        apply_cloudformation(&plan, session, event_sink).await
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

async fn apply_cloudformation(
    plan: &InstallPlan,
    session: &mut InstallSession,
    event_sink: &mut dyn InstallEventSink,
) -> Result<ApplyResult, AdapterError> {
    let context = CloudFormationContext::from_plan(plan)?;
    let mut artifacts = BTreeMap::new();
    let mut account_id: Option<String> = None;
    let mut template_url: Option<String> = None;

    let mut progress = StackProgress {
        operation: None,
        waiter: WaiterKind::CreateComplete,
        wait_required: false,
    };

    for step in &plan.deploy_steps {
        emit_step_started(session, event_sink, step).await;

        match step.id.as_str() {
            "validate-environment" => {
                let aws_account_id = validate_cloudformation_environment(&context).await?;
                artifacts.insert("aws_account_id".into(), aws_account_id.clone());
                session
                    .artifacts
                    .insert("aws_account_id".into(), aws_account_id.clone());
                event_sink
                    .emit(InstallEvent::ArtifactRecorded {
                        key: "aws_account_id".into(),
                        value: aws_account_id.clone(),
                    })
                    .await;
                account_id = Some(aws_account_id);
                event_sink
                    .emit(InstallEvent::LogLine {
                        message: "AWS identity validated".into(),
                    })
                    .await;
            }
            "stage-template" => {
                let aws_account_id = account_id.as_deref().ok_or_else(|| {
                    AdapterError::Message(
                        "AWS account ID missing before CloudFormation template upload".into(),
                    )
                })?;
                let staged_template =
                    stage_cloudformation_template(&context, aws_account_id, event_sink).await?;
                for (key, value) in [
                    (
                        "template_bucket".to_string(),
                        staged_template.bucket.clone(),
                    ),
                    ("template_url".to_string(), staged_template.url.clone()),
                ] {
                    artifacts.insert(key.clone(), value.clone());
                    session.artifacts.insert(key.clone(), value.clone());
                    event_sink
                        .emit(InstallEvent::ArtifactRecorded { key, value })
                        .await;
                }
                template_url = Some(staged_template.url);
            }
            "create-stack" => {
                progress = prepare_stack_progress(&context).await?;
                progress = run_stack_operation_if_needed(
                    &context,
                    template_url.as_deref().ok_or_else(|| {
                        AdapterError::Message(
                            "CloudFormation template URL missing before stack operation".into(),
                        )
                    })?,
                    progress,
                    event_sink,
                )
                .await?;
            }
            "wait-stack" => {
                let stack_artifacts = if progress.wait_required {
                    wait_for_stack_completion(&context, progress.waiter, event_sink).await?
                } else {
                    describe_stack_artifacts(&context).await?
                };
                for (key, value) in &stack_artifacts {
                    event_sink
                        .emit(InstallEvent::ArtifactRecorded {
                            key: key.clone(),
                            value: value.clone(),
                        })
                        .await;
                }
                session.artifacts.extend(stack_artifacts.clone());
                artifacts.extend(stack_artifacts);
            }
            "emit-post-install" => {
                event_sink
                    .emit(InstallEvent::LogLine {
                        message: format!(
                            "CloudFormation outputs ready for stack {}",
                            context.stack_name
                        ),
                    })
                    .await;
            }
            _ => {}
        }

        emit_step_finished(event_sink, step, "completed").await;
    }

    update_session_phase(session, InstallPhase::PostInstall);
    artifacts
        .entry("stack_name".into())
        .or_insert_with(|| context.stack_name.clone());

    Ok(ApplyResult {
        final_phase: InstallPhase::PostInstall,
        artifacts,
        post_install_steps: plan.post_install_steps.clone(),
    })
}

#[derive(Debug, Clone)]
struct CloudFormationContext {
    stack_name: String,
    region: String,
    template_path: String,
    capabilities: String,
    pack: String,
    profile: String,
    parameter_overrides: Vec<(String, String)>,
}

impl CloudFormationContext {
    fn from_plan(plan: &InstallPlan) -> Result<Self, AdapterError> {
        let stack_name = plan.resolved_stack_name.clone().ok_or_else(|| {
            AdapterError::Message("stack name is required for CloudFormation".into())
        })?;
        let region = plan.resolved_region.clone();
        let template_path = plan
            .adapter_options
            .get("template_path")
            .cloned()
            .unwrap_or_else(|| "deploy/cloudformation/template.yaml".into());
        let capabilities = plan
            .adapter_options
            .get("capabilities")
            .cloned()
            .unwrap_or_else(|| "CAPABILITY_NAMED_IAM".into());

        let mut parameter_overrides = Vec::new();
        parameter_overrides.push(("EnvironmentName".into(), stack_name.clone()));
        for (key, value) in &plan.adapter_options {
            if let Some(parameter_name) = adapter_option_to_cfn_parameter(key) {
                parameter_overrides.push((parameter_name.to_string(), value.clone()));
            }
        }

        Ok(Self {
            stack_name,
            region,
            template_path: resolve_repo_path(&template_path)?,
            capabilities,
            pack: plan.resolved_pack.id.clone(),
            profile: plan.resolved_profile.id.clone(),
            parameter_overrides,
        })
    }
}

async fn validate_cloudformation_environment(
    context: &CloudFormationContext,
) -> Result<String, AdapterError> {
    if !Path::new(&context.template_path).exists() {
        return Err(AdapterError::Message(format!(
            "CloudFormation template not found at {} — verify the repo checkout includes deploy/cloudformation/template.yaml",
            context.template_path
        )));
    }

    let output = run_command(&build_validate_identity_command(Some(&context.region))).await?;
    if output.success() {
        let identity: CallerIdentityResponse =
            serde_json::from_str(&output.stdout).map_err(|source| {
                AdapterError::Message(format!(
                    "Failed to parse AWS caller identity JSON — {source}"
                ))
            })?;
        return Ok(identity.account);
    }

    Err(map_aws_command_failure(
        &output,
        "AWS credentials not found — run aws configure or export AWS_ACCESS_KEY_ID",
        Some(&context.region),
    ))
}

async fn prepare_stack_progress(
    context: &CloudFormationContext,
) -> Result<StackProgress, AdapterError> {
    let output = run_command(&build_describe_stack_command(
        &context.stack_name,
        &context.region,
    ))
    .await?;

    if output.success() {
        let status = parse_stack_status(&output.stdout)?;
        if is_rollback_status(&status) {
            return Err(rollback_error(
                &context.stack_name,
                &context.region,
                &status,
            ));
        }

        if status.ends_with("_IN_PROGRESS") {
            let waiter = waiter_kind_for_status(&status);
            return Ok(StackProgress {
                operation: None,
                waiter,
                wait_required: true,
            });
        }

        return Ok(StackProgress {
            operation: Some(StackOperation::Update),
            waiter: WaiterKind::UpdateComplete,
            wait_required: true,
        });
    }

    if stack_missing(&output.stderr) {
        return Ok(StackProgress {
            operation: Some(StackOperation::Create),
            waiter: WaiterKind::CreateComplete,
            wait_required: true,
        });
    }

    Err(map_aws_command_failure(
        &output,
        "Failed to inspect CloudFormation stack state — verify the stack name and AWS permissions",
        Some(&context.region),
    ))
}

async fn run_stack_operation_if_needed(
    context: &CloudFormationContext,
    template_url: &str,
    mut progress: StackProgress,
    event_sink: &mut dyn InstallEventSink,
) -> Result<StackProgress, AdapterError> {
    let Some(operation) = progress.operation else {
        event_sink
            .emit(InstallEvent::LogLine {
                message: "Existing CloudFormation operation in progress; waiting for completion"
                    .into(),
            })
            .await;
        return Ok(progress);
    };

    let parameter_overrides = context
        .parameter_overrides
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect::<Vec<_>>();

    let output = run_command(&build_apply_stack_command(ApplyStackCommandInput {
        operation,
        stack_name: &context.stack_name,
        region: &context.region,
        template_url,
        capabilities: &context.capabilities,
        pack: &context.pack,
        profile: &context.profile,
        parameter_overrides: &parameter_overrides,
    }))
    .await?;

    if output.success() {
        return Ok(progress);
    }

    if operation == StackOperation::Update && no_updates_needed(&output.stderr) {
        event_sink
            .emit(InstallEvent::LogLine {
                message: "No CloudFormation updates were necessary".into(),
            })
            .await;
        progress.wait_required = false;
        return Ok(progress);
    }

    Err(map_aws_command_failure(
        &output,
        "CloudFormation deployment command failed — inspect the AWS CLI output above for the rejected parameter or permission",
        Some(&context.region),
    ))
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct StagedTemplate {
    bucket: String,
    url: String,
}

async fn stage_cloudformation_template(
    context: &CloudFormationContext,
    account_id: &str,
    event_sink: &mut dyn InstallEventSink,
) -> Result<StagedTemplate, AdapterError> {
    let bucket = format!("loki-deploy-{account_id}");
    let object_key = format!("loki-installer/{}/template.yaml", context.stack_name);
    let template_url = format!("https://s3.amazonaws.com/{bucket}/{object_key}");

    let create_bucket = run_command(&build_create_bucket_command(&bucket, &context.region)).await?;
    if !create_bucket.success() && !bucket_already_owned(&create_bucket.stderr) {
        return Err(map_aws_command_failure(
            &create_bucket,
            "Failed to create CloudFormation template bucket",
            Some(&context.region),
        ));
    }

    // Block all public access — private bucket, CFN reads via same-account S3 access
    let _ = run_command(&CommandSpec {
        program: "aws".into(),
        args: vec![
            "s3api".into(), "put-public-access-block".into(),
            "--bucket".into(), bucket.clone(),
            "--public-access-block-configuration".into(),
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true".into(),
            "--region".into(), context.region.clone(),
        ],
        current_dir: None,
    }).await;

    // Enable SSE-S3 encryption
    let _ = run_command(&CommandSpec {
        program: "aws".into(),
        args: vec![
            "s3api".into(),
            "put-bucket-encryption".into(),
            "--bucket".into(),
            bucket.clone(),
            "--server-side-encryption-configuration".into(),
            r#"{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}"#
                .into(),
            "--region".into(),
            context.region.clone(),
        ],
        current_dir: None,
    })
    .await;

    let upload = run_command(&build_upload_template_command(
        &context.template_path,
        &bucket,
        &context.stack_name,
        &context.region,
    ))
    .await?;
    if !upload.success() {
        return Err(map_aws_command_failure(
            &upload,
            "Failed to upload CloudFormation template to S3",
            Some(&context.region),
        ));
    }

    event_sink
        .emit(InstallEvent::LogLine {
            message: format!("Uploaded CloudFormation template to {template_url}"),
        })
        .await;

    Ok(StagedTemplate {
        bucket,
        url: template_url,
    })
}

async fn wait_for_stack_completion(
    context: &CloudFormationContext,
    waiter: WaiterKind,
    event_sink: &mut dyn InstallEventSink,
) -> Result<BTreeMap<String, String>, AdapterError> {
    let waiter_spec = build_wait_stack_command(&context.stack_name, &context.region, waiter);
    let mut child = spawn_child(&waiter_spec)?;
    let mut seen_events = BTreeSet::new();

    loop {
        tokio::select! {
            status = child.wait() => {
                let status = status.map_err(|source| AdapterError::Message(format!(
                    "CloudFormation waiter failed to execute — {source}"
                )))?;

                emit_stack_events(context, &mut seen_events, event_sink).await?;

                let artifacts = describe_stack_artifacts(context).await?;
                if !status.success() {
                    let stack_status = artifacts
                        .get("stack_status")
                        .cloned()
                        .unwrap_or_else(|| "UNKNOWN".into());
                    if is_rollback_status(&stack_status) {
                        return Err(rollback_error(&context.stack_name, &context.region, &stack_status));
                    }
                    return Err(AdapterError::Message(format!(
                        "CloudFormation wait failed with stack status {stack_status} — run aws cloudformation describe-stack-events --stack-name {} --region {}",
                        context.stack_name, context.region
                    )));
                }

                return Ok(artifacts);
            }
            _ = sleep(STACK_EVENT_POLL_INTERVAL) => {
                emit_stack_events(context, &mut seen_events, event_sink).await?;
            }
        }
    }
}

async fn emit_stack_events(
    context: &CloudFormationContext,
    seen_events: &mut BTreeSet<String>,
    event_sink: &mut dyn InstallEventSink,
) -> Result<(), AdapterError> {
    let output = run_command(&build_describe_stack_events_command(
        &context.stack_name,
        &context.region,
    ))
    .await?;
    if !output.success() {
        return Ok(());
    }

    let response: DescribeStackEventsResponse =
        serde_json::from_str(&output.stdout).map_err(|source| {
            AdapterError::Message(format!(
                "Failed to parse CloudFormation stack events JSON — {source}"
            ))
        })?;

    let mut new_events = Vec::new();
    for event in response.stack_events.into_iter().rev() {
        if seen_events.insert(event.event_id.clone()) {
            new_events.push(event);
        }
    }

    for event in new_events {
        if let Some(reason) = event.resource_status_reason
            && !reason.is_empty()
        {
            event_sink
                .emit(InstallEvent::LogLine { message: reason })
                .await;
        }

        event_sink
            .emit(InstallEvent::StackEvent {
                resource: event.logical_resource_id,
                status: event.resource_status,
                resource_type: event.resource_type,
            })
            .await;
    }

    Ok(())
}

async fn describe_stack_artifacts(
    context: &CloudFormationContext,
) -> Result<BTreeMap<String, String>, AdapterError> {
    let output = run_command(&build_describe_stack_command(
        &context.stack_name,
        &context.region,
    ))
    .await?;
    if !output.success() {
        return Err(map_aws_command_failure(
            &output,
            "Failed to read CloudFormation stack outputs after deployment",
            Some(&context.region),
        ));
    }

    let mut artifacts = parse_stack_artifacts(&output.stdout)?;
    artifacts.insert("stack_name".into(), context.stack_name.clone());
    Ok(artifacts)
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
            display_name: step.display_name.clone(),
        })
        .await;
}

fn build_validate_identity_command(region: Option<&str>) -> CommandSpec {
    let mut args = vec![
        "sts".into(),
        "get-caller-identity".into(),
        "--output".into(),
        "json".into(),
    ];
    if let Some(region) = region {
        args.push("--region".into());
        args.push(region.into());
    }
    CommandSpec {
        program: "aws".into(),
        args,
        current_dir: None,
    }
}

fn build_describe_stack_command(stack_name: &str, region: &str) -> CommandSpec {
    CommandSpec {
        program: "aws".into(),
        args: vec![
            "cloudformation".into(),
            "describe-stacks".into(),
            "--stack-name".into(),
            stack_name.into(),
            "--output".into(),
            "json".into(),
            "--region".into(),
            region.into(),
        ],
        current_dir: None,
    }
}

fn build_describe_stack_events_command(stack_name: &str, region: &str) -> CommandSpec {
    CommandSpec {
        program: "aws".into(),
        args: vec![
            "cloudformation".into(),
            "describe-stack-events".into(),
            "--stack-name".into(),
            stack_name.into(),
            "--output".into(),
            "json".into(),
            "--region".into(),
            region.into(),
        ],
        current_dir: None,
    }
}

struct ApplyStackCommandInput<'a> {
    operation: StackOperation,
    stack_name: &'a str,
    region: &'a str,
    template_url: &'a str,
    capabilities: &'a str,
    pack: &'a str,
    profile: &'a str,
    parameter_overrides: &'a [(&'a str, &'a str)],
}

fn build_apply_stack_command(input: ApplyStackCommandInput<'_>) -> CommandSpec {
    let mut args = vec![
        "cloudformation".into(),
        match input.operation {
            StackOperation::Create => "create-stack".into(),
            StackOperation::Update => "update-stack".into(),
        },
        "--stack-name".into(),
        input.stack_name.into(),
        "--template-url".into(),
        input.template_url.into(),
        "--capabilities".into(),
        input.capabilities.into(),
        "--parameters".into(),
        format!("ParameterKey=PackName,ParameterValue={}", input.pack),
        format!("ParameterKey=ProfileName,ParameterValue={}", input.profile),
    ];

    for (key, value) in input.parameter_overrides {
        args.push(format!("ParameterKey={key},ParameterValue={value}"));
    }

    args.push("--region".into());
    args.push(input.region.into());

    CommandSpec {
        program: "aws".into(),
        args,
        current_dir: None,
    }
}

fn build_create_bucket_command(bucket: &str, region: &str) -> CommandSpec {
    let mut args = vec![
        "s3api".into(),
        "create-bucket".into(),
        "--bucket".into(),
        bucket.into(),
        "--region".into(),
        region.into(),
    ];

    if region != "us-east-1" {
        args.push("--create-bucket-configuration".into());
        args.push(format!("LocationConstraint={region}"));
    }

    CommandSpec {
        program: "aws".into(),
        args,
        current_dir: None,
    }
}

fn build_upload_template_command(
    template_path: &str,
    bucket: &str,
    stack_name: &str,
    region: &str,
) -> CommandSpec {
    CommandSpec {
        program: "aws".into(),
        args: vec![
            "s3".into(),
            "cp".into(),
            template_path.into(),
            format!("s3://{bucket}/loki-installer/{stack_name}/template.yaml"),
            "--region".into(),
            region.into(),
        ],
        current_dir: None,
    }
}

fn adapter_option_to_cfn_parameter(key: &str) -> Option<&'static str> {
    match key {
        "model" => Some("DefaultModel"),
        "port" => Some("OpenClawGatewayPort"),
        "bedrockify_port" => Some("BedrockifyPort"),
        "embed_model" => Some("EmbedModel"),
        "hermes_model" => Some("HermesModel"),
        "haiku_model" => Some("HaikuModel"),
        "sandbox_name" => Some("SandboxName"),
        "telegram_token" => Some("TelegramToken"),
        "allowed_chat_ids" => Some("AllowedChatIds"),
        "template_path" | "capabilities" | "pack" | "profile" | "region" => None,
        _ => None,
    }
}

fn build_wait_stack_command(stack_name: &str, region: &str, waiter: WaiterKind) -> CommandSpec {
    let waiter_name = match waiter {
        WaiterKind::CreateComplete => "stack-create-complete",
        WaiterKind::UpdateComplete => "stack-update-complete",
    };

    CommandSpec {
        program: "aws".into(),
        args: vec![
            "cloudformation".into(),
            "wait".into(),
            waiter_name.into(),
            "--stack-name".into(),
            stack_name.into(),
            "--region".into(),
            region.into(),
        ],
        current_dir: None,
    }
}

fn parse_stack_status(raw: &str) -> Result<String, AdapterError> {
    let response: DescribeStacksResponse = serde_json::from_str(raw).map_err(|source| {
        AdapterError::Message(format!(
            "Failed to parse CloudFormation stack JSON — {source}"
        ))
    })?;
    let stack = response.stacks.into_iter().next().ok_or_else(|| {
        AdapterError::Message("CloudFormation describe-stacks returned no stacks".into())
    })?;
    Ok(stack.stack_status)
}

fn parse_stack_artifacts(raw: &str) -> Result<BTreeMap<String, String>, AdapterError> {
    let response: DescribeStacksResponse = serde_json::from_str(raw).map_err(|source| {
        AdapterError::Message(format!(
            "Failed to parse CloudFormation stack JSON — {source}"
        ))
    })?;
    let stack = response.stacks.into_iter().next().ok_or_else(|| {
        AdapterError::Message("CloudFormation describe-stacks returned no stacks".into())
    })?;

    if is_rollback_status(&stack.stack_status) {
        return Err(rollback_error("unknown", "unknown", &stack.stack_status));
    }

    let mut artifacts = BTreeMap::new();
    artifacts.insert("stack_status".into(), stack.stack_status.clone());
    for output in stack.outputs {
        match output.output_key.as_str() {
            "InstanceId" => {
                artifacts.insert("instance_id".into(), output.output_value);
            }
            "PublicIp" => {
                artifacts.insert("public_ip".into(), output.output_value);
            }
            _ => {}
        }
    }
    Ok(artifacts)
}

fn stack_missing(stderr: &str) -> bool {
    stderr.contains("does not exist") || stderr.contains("ValidationError")
}

fn no_updates_needed(stderr: &str) -> bool {
    stderr.contains("No updates are to be performed")
}

fn bucket_already_owned(stderr: &str) -> bool {
    stderr.contains("BucketAlreadyOwnedByYou")
}

fn waiter_kind_for_status(status: &str) -> WaiterKind {
    if status.starts_with("UPDATE_") {
        WaiterKind::UpdateComplete
    } else {
        WaiterKind::CreateComplete
    }
}

fn is_rollback_status(status: &str) -> bool {
    matches!(
        status,
        "ROLLBACK_IN_PROGRESS"
            | "ROLLBACK_COMPLETE"
            | "ROLLBACK_FAILED"
            | "UPDATE_ROLLBACK_IN_PROGRESS"
            | "UPDATE_ROLLBACK_COMPLETE"
            | "UPDATE_ROLLBACK_FAILED"
    )
}

fn rollback_error(stack_name: &str, region: &str, status: &str) -> AdapterError {
    AdapterError::Message(format!(
        "CloudFormation stack {stack_name} entered {status} — check stack events with aws cloudformation describe-stack-events --stack-name {stack_name} --region {region}"
    ))
}

fn map_aws_command_failure(
    output: &CommandOutput,
    default_message: &str,
    region: Option<&str>,
) -> AdapterError {
    let stderr = output.stderr.trim();
    if stderr.contains("Unable to locate credentials")
        || stderr.contains("Could not find credentials")
        || stderr.contains("InvalidClientTokenId")
        || stderr.contains("ExpiredToken")
    {
        return AdapterError::Message(
            "AWS credentials not found — run aws configure or export AWS_ACCESS_KEY_ID".into(),
        );
    }

    if stderr.contains("You must specify a region") || stderr.contains("Invalid endpoint") {
        return AdapterError::Message(
            "AWS region not configured — pass --region or export AWS_REGION".into(),
        );
    }

    if stderr.contains("Unable to locate executable file")
        || stderr.contains("command not found")
        || stderr.contains("No such file or directory")
    {
        return AdapterError::Message(
            "AWS CLI not found — install awscli v2 and re-run the installer".into(),
        );
    }

    let mut message = default_message.to_string();
    if let Some(region) = region {
        message.push_str(&format!(" in region {region}"));
    }
    if !stderr.is_empty() {
        message.push_str(": ");
        message.push_str(stderr);
    }
    AdapterError::Message(message)
}

#[cfg(test)]
mod tests {
    use super::{
        ApplyStackCommandInput, StackOperation, adapter_option_to_cfn_parameter,
        build_apply_stack_command, build_create_bucket_command, build_upload_template_command,
        build_validate_identity_command, parse_stack_artifacts,
    };

    #[test]
    fn validate_uses_sts_get_caller_identity_json() {
        let command = build_validate_identity_command(Some("us-east-1"));
        assert_eq!(command.program, "aws");
        assert_eq!(
            command.args,
            vec![
                "sts",
                "get-caller-identity",
                "--output",
                "json",
                "--region",
                "us-east-1",
            ]
        );
    }

    #[test]
    fn create_stack_command_includes_template_capabilities_and_parameters() {
        let command = build_apply_stack_command(ApplyStackCommandInput {
            operation: StackOperation::Create,
            stack_name: "loki-openclaw",
            region: "us-east-1",
            template_url: "https://s3.amazonaws.com/loki-deploy-123456789012/loki-installer/loki-openclaw/template.yaml",
            capabilities: "CAPABILITY_NAMED_IAM",
            pack: "openclaw",
            profile: "builder",
            parameter_overrides: &[
                ("EnvironmentName", "loki-openclaw"),
                ("DefaultModel", "us.anthropic.claude-opus-4-6-v1"),
                ("OpenClawGatewayPort", "3001"),
            ],
        });

        assert_eq!(command.program, "aws");
        assert_eq!(
            command.args[0..4],
            [
                "cloudformation",
                "create-stack",
                "--stack-name",
                "loki-openclaw"
            ]
        );
        assert!(command.args.contains(&"--template-url".into()));
        assert!(
            command
                .args
                .contains(
                    &"https://s3.amazonaws.com/loki-deploy-123456789012/loki-installer/loki-openclaw/template.yaml".into()
                )
        );
        assert!(command.args.contains(&"--capabilities".into()));
        assert!(command.args.contains(&"CAPABILITY_NAMED_IAM".into()));
        assert!(command.args.contains(&"--parameters".into()));
        assert!(
            command
                .args
                .contains(&"ParameterKey=PackName,ParameterValue=openclaw".into())
        );
        assert!(
            command
                .args
                .contains(&"ParameterKey=ProfileName,ParameterValue=builder".into())
        );
        assert!(
            command
                .args
                .contains(&"ParameterKey=EnvironmentName,ParameterValue=loki-openclaw".into())
        );
        assert_eq!(
            command
                .args
                .iter()
                .filter(|arg| *arg == "ParameterKey=EnvironmentName,ParameterValue=loki-openclaw")
                .count(),
            1
        );
        assert!(
            command
                .args
                .ends_with(&["--region".into(), "us-east-1".into()])
        );
    }

    #[test]
    fn create_bucket_command_omits_location_constraint_for_us_east_1() {
        let command = build_create_bucket_command("loki-deploy-123456789012", "us-east-1");

        assert_eq!(command.program, "aws");
        assert_eq!(
            command.args,
            vec![
                "s3api",
                "create-bucket",
                "--bucket",
                "loki-deploy-123456789012",
                "--region",
                "us-east-1",
            ]
        );
    }

    #[test]
    fn upload_template_command_targets_stack_scoped_s3_path() {
        let command = build_upload_template_command(
            "/tmp/template.yaml",
            "loki-deploy-123456789012",
            "loki-openclaw",
            "us-east-1",
        );

        assert_eq!(command.program, "aws");
        assert_eq!(
            command.args,
            vec![
                "s3",
                "cp",
                "/tmp/template.yaml",
                "s3://loki-deploy-123456789012/loki-installer/loki-openclaw/template.yaml",
                "--region",
                "us-east-1",
            ]
        );
    }

    #[test]
    fn cfn_parameter_mapping_covers_pack_specific_options() {
        assert_eq!(
            adapter_option_to_cfn_parameter("bedrockify_port"),
            Some("BedrockifyPort")
        );
        assert_eq!(
            adapter_option_to_cfn_parameter("embed_model"),
            Some("EmbedModel")
        );
        assert_eq!(
            adapter_option_to_cfn_parameter("hermes_model"),
            Some("HermesModel")
        );
        assert_eq!(
            adapter_option_to_cfn_parameter("haiku_model"),
            Some("HaikuModel")
        );
        assert_eq!(
            adapter_option_to_cfn_parameter("sandbox_name"),
            Some("SandboxName")
        );
        assert_eq!(
            adapter_option_to_cfn_parameter("telegram_token"),
            Some("TelegramToken")
        );
        assert_eq!(
            adapter_option_to_cfn_parameter("allowed_chat_ids"),
            Some("AllowedChatIds")
        );
        assert_eq!(adapter_option_to_cfn_parameter("capabilities"), None);
    }

    #[test]
    fn parse_stack_artifacts_extracts_outputs_and_status() {
        let artifacts = parse_stack_artifacts(
            r#"{
              "Stacks": [{
                "StackStatus": "CREATE_COMPLETE",
                "Outputs": [
                  {"OutputKey": "InstanceId", "OutputValue": "i-123"},
                  {"OutputKey": "PublicIp", "OutputValue": "1.2.3.4"}
                ]
              }]
            }"#,
        )
        .expect("parse stack outputs");

        assert_eq!(
            artifacts.get("stack_status"),
            Some(&"CREATE_COMPLETE".into())
        );
        assert_eq!(artifacts.get("instance_id"), Some(&"i-123".into()));
        assert_eq!(artifacts.get("public_ip"), Some(&"1.2.3.4".into()));
    }

    #[test]
    fn parse_stack_artifacts_rejects_rollback_statuses() {
        let error = parse_stack_artifacts(
            r#"{
              "Stacks": [{
                "StackStatus": "UPDATE_ROLLBACK_COMPLETE",
                "Outputs": []
              }]
            }"#,
        )
        .expect_err("rollback should fail");

        let message = error.to_string();
        assert!(message.contains("UPDATE_ROLLBACK_COMPLETE"));
        assert!(message.contains("check stack events"));
    }
}
