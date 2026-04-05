//! Terraform deployment adapter.

use crate::adapters::support::{
    CommandOutput, CommandSpec, resolve_repo_path_from, run_command, run_command_streaming,
};
use crate::core::{
    AdapterError, AdapterPlan, AdapterValidationError, ApplyResult, DeployAction, DeployAdapter,
    DeployMethodId, DeployStatus, DeployStep, InstallEvent, InstallEventSink, InstallPhase,
    InstallPlan, InstallRequest, InstallSession, MethodManifest, PackManifest, PlanWarning,
    PostInstallStep, PrerequisiteCheck, PrerequisiteKind, ProfileManifest, UninstallResult,
    update_session_phase,
};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct TerraformAdapter;
const DEFAULT_TERRAFORM_VERSION: &str = "1.12.1";
const TERRAFORM_PATH_ENV: &str = "PATH";
const TERRAFORM_VERSION_ENV: &str = "LOKI_INSTALLER_TERRAFORM_VERSION";

#[derive(Debug, Clone)]
struct TerraformContext {
    terraform_bin: String,
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
        _session: &InstallSession,
        _event_sink: &mut dyn InstallEventSink,
    ) -> Result<UninstallResult, AdapterError> {
        Err(AdapterError::Message(
            "Uninstall is not supported yet. Coming soon.".into(),
        ))
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
    fn from_plan(plan: &InstallPlan, terraform_bin: String) -> Result<Self, AdapterError> {
        let working_dir = resolve_repo_path_from(
            plan.adapter_options.get("repo_root").map(String::as_str),
            plan.adapter_options
                .get("working_dir")
                .map(String::as_str)
                .unwrap_or("deploy/terraform"),
        )?;
        let environment_name = plan
            .resolved_stack_name
            .clone()
            .unwrap_or_else(|| {
                let suffix = &uuid::Uuid::new_v4().to_string()[..8];
                format!("loki-{}-{suffix}", plan.resolved_pack.id)
            });

        Ok(Self {
            terraform_bin,
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
    if session.phase == InstallPhase::PostInstall {
        return Ok(completed_apply_result(plan, session));
    }

    let terraform_bin = ensure_terraform_installed(event_sink)?;
    let context = TerraformContext::from_plan(plan, terraform_bin)?;
    if !Path::new(&context.working_dir).exists() {
        return Err(AdapterError::Message(format!(
            "Terraform working directory not found at {} — verify the repo checkout includes deploy/terraform",
            context.working_dir
        )));
    }

    let mut artifacts = BTreeMap::new();

    for step in &plan.deploy_steps {
        if phase_is_past(session.phase, step.phase) {
            event_sink
                .emit(InstallEvent::LogLine {
                    message: format!(
                        "Skipping {} on resume; phase {} already completed",
                        step.display_name, step.phase
                    ),
                })
                .await;
            continue;
        }

        emit_step_started(session, event_sink, step).await;

        match step.id.as_str() {
            "terraform-init" => {
                let output = run_command(&build_terraform_init_command(&context)).await?;
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
                let output =
                    run_command(&build_terraform_plan_command(&context, &context.tf_vars)).await?;
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
                let output =
                    run_command_streaming(&build_terraform_apply_command(&context), event_sink)
                        .await?;
                let apply_output = if output.success() {
                    output
                } else {
                    let combined_output = format!("{}\n{}", output.stderr, output.stdout);
                    let is_existing_resource_error = combined_output
                        .contains("EntityAlreadyExists")
                        || combined_output
                            .to_ascii_lowercase()
                            .contains("already exists");
                    let existing_resources = parse_existing_resources(&combined_output);

                    if is_existing_resource_error && !existing_resources.is_empty() {
                        let retry_tf_vars =
                            with_tf_var(&context.tf_vars, "enable_satellite_services", "false");
                        for (resource_address, import_id) in existing_resources {
                            event_sink
                                .emit(InstallEvent::LogLine {
                                    message: format!(
                                        "Auto-importing pre-existing resource: {resource_address} ({import_id})"
                                    ),
                                })
                                .await;
                            run_terraform_import(&context, &resource_address, &import_id).await?;
                        }

                        let retry_plan =
                            run_command(&build_terraform_plan_command(&context, &retry_tf_vars))
                                .await?;
                        ensure_terraform_success(
                            &retry_plan,
                            "Terraform plan failed — fix the reported variable or provider issue and retry",
                        )?;
                        record_command_artifact(
                            "terraform_plan_output",
                            retry_plan,
                            &mut artifacts,
                            event_sink,
                        )
                        .await;

                        let retry_apply = run_command_streaming(
                            &build_terraform_apply_command(&context),
                            event_sink,
                        )
                        .await?;
                        ensure_terraform_success(
                            &retry_apply,
                            "Terraform apply failed — inspect the Terraform output for the rejected AWS resource or permission",
                        )?;
                        retry_apply
                    } else {
                        ensure_terraform_success(
                            &output,
                            "Terraform apply failed — inspect the Terraform output for the rejected AWS resource or permission",
                        )?;
                        output
                    }
                };
                record_command_artifact(
                    "terraform_apply_output",
                    apply_output,
                    &mut artifacts,
                    event_sink,
                )
                .await;
            }
            "terraform-health" => {
                let output = run_command(&build_terraform_output_command(&context)).await?;
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

fn build_terraform_init_command(context: &TerraformContext) -> CommandSpec {
    CommandSpec {
        program: context.terraform_bin.clone(),
        args: vec![
            format!("-chdir={}", context.working_dir),
            "init".into(),
            "-no-color".into(),
            "-input=false".into(),
        ],
        current_dir: None,
    }
}

fn build_terraform_plan_command(
    context: &TerraformContext,
    tf_vars: &[(String, String)],
) -> CommandSpec {
    let mut args = vec![
        format!("-chdir={}", context.working_dir),
        "plan".into(),
        "-no-color".into(),
        "-input=false".into(),
        format!("-out={}", context.plan_file),
        format!("-var=aws_region={}", context.region),
        format!("-var=pack_name={}", context.pack),
        format!("-var=profile_name={}", context.profile),
        format!("-var=environment_name={}", context.environment_name),
    ];
    for (name, value) in tf_vars {
        args.push(format!("-var={name}={value}"));
    }

    CommandSpec {
        program: context.terraform_bin.clone(),
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
        "enable_satellite_services" => Some("enable_satellite_services"),
        "working_dir" | "pack" | "profile" | "region" | "workspace" | "repo_root" => None,
        _ => None,
    }
}

fn build_terraform_apply_command(context: &TerraformContext) -> CommandSpec {
    CommandSpec {
        program: context.terraform_bin.clone(),
        args: vec![
            format!("-chdir={}", context.working_dir),
            "apply".into(),
            "-no-color".into(),
            "-input=false".into(),
            "-auto-approve".into(),
            context.plan_file.clone(),
        ],
        current_dir: None,
    }
}

fn with_tf_var(tf_vars: &[(String, String)], name: &str, value: &str) -> Vec<(String, String)> {
    let mut updated = tf_vars.to_vec();
    if let Some((_, existing_value)) = updated.iter_mut().find(|(key, _)| key == name) {
        *existing_value = value.to_string();
    } else {
        updated.push((name.to_string(), value.to_string()));
    }
    updated
}

fn build_terraform_output_command(context: &TerraformContext) -> CommandSpec {
    CommandSpec {
        program: context.terraform_bin.clone(),
        args: vec![
            format!("-chdir={}", context.working_dir),
            "output".into(),
            "-json".into(),
            "-no-color".into(),
        ],
        current_dir: None,
    }
}

fn build_terraform_import_command(
    context: &TerraformContext,
    resource_address: &str,
    import_id: &str,
) -> CommandSpec {
    CommandSpec {
        program: context.terraform_bin.clone(),
        args: vec![
            format!("-chdir={}", context.working_dir),
            "import".into(),
            "-no-color".into(),
            resource_address.into(),
            import_id.into(),
        ],
        current_dir: None,
    }
}

async fn run_terraform_import(
    context: &TerraformContext,
    resource_address: &str,
    import_id: &str,
) -> Result<CommandOutput, AdapterError> {
    let output = run_command(&build_terraform_import_command(
        context,
        resource_address,
        import_id,
    ))
    .await?;
    ensure_terraform_success(
        &output,
        "Terraform import failed — inspect the Terraform output for the rejected AWS resource or permission",
    )?;
    Ok(output)
}

fn ensure_terraform_installed(
    event_sink: &mut dyn InstallEventSink,
) -> Result<String, AdapterError> {
    if let Some(terraform_bin) = resolve_existing_terraform_binary() {
        return Ok(terraform_bin);
    }

    emit_sync_log(event_sink, "Terraform not found — installing...")?;

    let version = std::env::var(TERRAFORM_VERSION_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_TERRAFORM_VERSION.to_string());
    let (os, arch) = terraform_platform()?;
    let install_path = terraform_install_path()?;
    if let Some(parent) = install_path.parent() {
        fs::create_dir_all(parent).map_err(|source| {
            AdapterError::Message(format!(
                "Failed to create terraform install directory {} — {source}",
                parent.display()
            ))
        })?;
    }

    let url = format!(
        "https://releases.hashicorp.com/terraform/{version}/terraform_{version}_{os}_{arch}.zip"
    );
    let archive_path = terraform_archive_path(&version);
    download_terraform_archive(&url, &archive_path)?;
    extract_terraform_binary(&archive_path, &install_path)?;
    prepend_local_bin_to_path(install_path.parent())?;
    emit_sync_log(
        event_sink,
        &format!("Terraform installed successfully (version {version})"),
    )?;
    let _ = fs::remove_file(&archive_path);

    Ok(install_path.display().to_string())
}

fn resolve_existing_terraform_binary() -> Option<String> {
    if let Some(path) = find_command_on_path("terraform")
        && Command::new(&path)
            .arg("version")
            .status()
            .is_ok_and(|status| status.success())
    {
        return Some(path.display().to_string());
    }

    None
}

fn terraform_platform() -> Result<(&'static str, &'static str), AdapterError> {
    let os = match std::env::consts::OS {
        "linux" => "linux",
        "macos" => "darwin",
        other => {
            return Err(AdapterError::Message(format!(
                "Terraform auto-install is unsupported on OS {other}"
            )));
        }
    };

    let arch = match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        other => {
            return Err(AdapterError::Message(format!(
                "Terraform auto-install is unsupported on architecture {other}"
            )));
        }
    };

    Ok((os, arch))
}

fn terraform_install_path() -> Result<PathBuf, AdapterError> {
    let home = std::env::var_os("HOME").ok_or_else(|| {
        AdapterError::Message(
            "HOME is not set, so the installer cannot place terraform in ~/.local/bin".into(),
        )
    })?;
    let primary = PathBuf::from(&home).join(".local/bin");
    // Fall back to /tmp/.local/bin when ~/.local/bin is on a read-only or
    // space-constrained filesystem (e.g. CloudShell).
    let dir = if can_write_to(&primary) { primary } else { PathBuf::from("/tmp/.local/bin") };
    fs::create_dir_all(&dir).map_err(|e| {
        AdapterError::Message(format!("Failed to create directory {} — {e}", dir.display()))
    })?;
    Ok(dir.join("terraform"))
}

fn can_write_to(dir: &Path) -> bool {
    if fs::create_dir_all(dir).is_err() {
        return false;
    }
    let probe = dir.join(".loki-probe");
    match fs::write(&probe, b"ok") {
        Ok(_) => { let _ = fs::remove_file(&probe); true }
        Err(_) => false,
    }
}

fn terraform_archive_path(version: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "loki-installer-terraform-{version}-{}.zip",
        std::process::id()
    ))
}

fn download_terraform_archive(url: &str, archive_path: &Path) -> Result<(), AdapterError> {
    let output = Command::new("curl")
        .args(["-fsSL", url, "-o"])
        .arg(archive_path)
        .output()
        .map_err(|source| {
            AdapterError::Message(format!(
                "Failed to start curl while downloading terraform from {url} — {source}"
            ))
        })?;
    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(AdapterError::Message(format!(
        "Failed to download terraform archive from {url} — {stderr}"
    )))
}

fn extract_terraform_binary(archive_path: &Path, install_path: &Path) -> Result<(), AdapterError> {
    let parent = install_path
        .parent()
        .ok_or_else(|| AdapterError::Message("install_path has no parent".into()))?;
    let output = Command::new("unzip")
        .args(["-o", "-j"])
        .arg(archive_path)
        .arg("terraform")
        .arg("-d")
        .arg(parent)
        .output()
        .map_err(|source| {
            AdapterError::Message(format!(
                "Failed to run unzip while extracting terraform to {} — {source}",
                install_path.display()
            ))
        })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(AdapterError::Message(format!(
            "Failed to extract terraform binary to {} — {stderr}",
            install_path.display()
        )));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(install_path)
            .map_err(|e| AdapterError::Message(format!("Failed to read terraform permissions — {e}")))?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(install_path, perms)
            .map_err(|e| AdapterError::Message(format!("Failed to chmod terraform — {e}")))?;
    }
    Ok(())
}

fn find_command_on_path(program: &str) -> Option<PathBuf> {
    std::env::var_os(TERRAFORM_PATH_ENV).and_then(|paths| {
        std::env::split_paths(&paths).find_map(|path| {
            let candidate = path.join(program);
            if candidate.is_file() {
                Some(candidate)
            } else {
                None
            }
        })
    })
}

fn prepend_local_bin_to_path(local_bin_dir: Option<&Path>) -> Result<(), AdapterError> {
    let Some(local_bin_dir) = local_bin_dir else {
        return Ok(());
    };

    let current_path = std::env::var_os(TERRAFORM_PATH_ENV).unwrap_or_default();
    let mut paths: Vec<PathBuf> = std::env::split_paths(&current_path).collect();
    if paths.iter().any(|path| path == local_bin_dir) {
        return Ok(());
    }

    paths.insert(0, local_bin_dir.to_path_buf());
    let joined = std::env::join_paths(paths).map_err(|source| {
        AdapterError::Message(format!(
            "Failed to update PATH for terraform install — {source}"
        ))
    })?;
    // Safety: the installer updates PATH within its own process so subsequent child processes can
    // discover the freshly installed terraform binary.
    unsafe {
        std::env::set_var(TERRAFORM_PATH_ENV, joined);
    }
    Ok(())
}

fn emit_sync_log(event_sink: &mut dyn InstallEventSink, message: &str) -> Result<(), AdapterError> {
    futures::executor::block_on(event_sink.emit(InstallEvent::LogLine {
        message: message.to_string(),
    }));
    Ok(())
}

fn parse_existing_resources(stderr: &str) -> Vec<(String, String)> {
    let mut resources = Vec::new();
    let mut current_error_line: Option<&str> = None;

    for line in stderr.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("Error:") {
            let is_existing_resource_error = trimmed.contains("EntityAlreadyExists")
                || trimmed.to_ascii_lowercase().contains("already exists");
            current_error_line = is_existing_resource_error.then_some(trimmed);
            continue;
        }

        let Some(error_line) = current_error_line else {
            continue;
        };

        let Some(resource_address) = parse_resource_address(trimmed) else {
            continue;
        };

        let Some(import_id) = extract_import_id(error_line, &resource_address) else {
            current_error_line = None;
            continue;
        };

        if !resources
            .iter()
            .any(|(address, id)| address == &resource_address && id == &import_id)
        {
            resources.push((resource_address, import_id));
        }
        current_error_line = None;
    }

    resources
}

fn parse_resource_address(line: &str) -> Option<String> {
    let rest = line.strip_prefix("with ")?;
    let address = rest.split(',').next()?.trim();
    (!address.is_empty()).then(|| address.to_string())
}

fn extract_import_id(error_line: &str, resource_address: &str) -> Option<String> {
    let resource_type = supported_resource_type(resource_address)?;
    match resource_type {
        "aws_iam_role" | "aws_iam_instance_profile" | "aws_s3_bucket" => {
            extract_parenthesized_value(error_line)
        }
        "aws_security_group" => extract_id_with_prefix(error_line, "sg-")
            .or_else(|| extract_parenthesized_value(error_line)),
        "aws_vpc" => extract_id_with_prefix(error_line, "vpc-")
            .or_else(|| extract_parenthesized_value(error_line)),
        _ => None,
    }
}

fn supported_resource_type(resource_address: &str) -> Option<&str> {
    resource_address
        .split('.')
        .find_map(|segment| match segment {
            "aws_iam_role" => Some("aws_iam_role"),
            "aws_iam_instance_profile" => Some("aws_iam_instance_profile"),
            "aws_s3_bucket" => Some("aws_s3_bucket"),
            "aws_security_group" => Some("aws_security_group"),
            "aws_vpc" => Some("aws_vpc"),
            _ => None,
        })
}

fn extract_parenthesized_value(line: &str) -> Option<String> {
    let start = line.find('(')?;
    let end = line[start + 1..].find(')')?;
    let value = line[start + 1..start + 1 + end].trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn extract_id_with_prefix(line: &str, prefix: &str) -> Option<String> {
    line.split(|c: char| c.is_whitespace() || matches!(c, '(' | ')' | ':' | ',' | ';' | '.'))
        .find(|token| token.starts_with(prefix))
        .map(str::to_string)
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
            display_name: step.display_name.clone(),
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

fn phase_rank(phase: InstallPhase) -> u8 {
    match phase {
        InstallPhase::ValidateEnvironment => 0,
        InstallPhase::DiscoverAwsContext => 1,
        InstallPhase::ResolveMetadata => 2,
        InstallPhase::PrepareDeployment => 3,
        InstallPhase::PlanDeployment => 4,
        InstallPhase::ApplyDeployment => 5,
        InstallPhase::WaitForResources => 6,
        InstallPhase::Finalize => 7,
        InstallPhase::PostInstall => 8,
    }
}

fn phase_is_past(current: InstallPhase, target: InstallPhase) -> bool {
    phase_rank(current) > phase_rank(target)
}

fn completed_apply_result(plan: &InstallPlan, session: &InstallSession) -> ApplyResult {
    ApplyResult {
        final_phase: InstallPhase::PostInstall,
        artifacts: session.artifacts.clone(),
        post_install_steps: plan.post_install_steps.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        TerraformContext, adapter_option_to_tf_var, build_terraform_apply_command,
        build_terraform_import_command, build_terraform_init_command, build_terraform_plan_command,
        parse_existing_resources, parse_terraform_outputs, phase_is_past,
    };
    use crate::core::InstallPhase;

    fn test_context() -> TerraformContext {
        TerraformContext {
            terraform_bin: "/usr/local/bin/terraform".into(),
            working_dir: "/tmp/repo/deploy/terraform".into(),
            plan_file: "/tmp/repo/tfplan".into(),
            region: "us-east-1".into(),
            pack: "openclaw".into(),
            profile: "builder".into(),
            environment_name: "loki-openclaw".into(),
            tf_vars: Vec::new(),
        }
    }

    #[test]
    fn terraform_init_command_uses_working_dir_and_non_interactive_flags() {
        let command = build_terraform_init_command(&test_context());
        assert_eq!(command.program, "/usr/local/bin/terraform");
        assert_eq!(
            command.args,
            vec![
                "-chdir=/tmp/repo/deploy/terraform",
                "init",
                "-no-color",
                "-input=false",
            ]
        );
    }

    #[test]
    fn terraform_plan_command_includes_outfile_and_tf_vars() {
        let command = build_terraform_plan_command(
            &test_context(),
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
        assert_eq!(command.program, "/usr/local/bin/terraform");
        assert!(command.args.contains(&"plan".into()));
        assert!(command.args.contains(&"-no-color".into()));
        assert!(command.args.contains(&"-input=false".into()));
        assert!(command.args.contains(&"-out=/tmp/repo/tfplan".into()));
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
            adapter_option_to_tf_var("enable_satellite_services"),
            Some("enable_satellite_services")
        );
        assert_eq!(adapter_option_to_tf_var("workspace"), None);
    }

    #[test]
    fn terraform_apply_command_uses_saved_plan() {
        let command = build_terraform_apply_command(&test_context());
        assert_eq!(command.program, "/usr/local/bin/terraform");
        assert_eq!(
            command.args,
            vec![
                "-chdir=/tmp/repo/deploy/terraform",
                "apply",
                "-no-color",
                "-input=false",
                "-auto-approve",
                "/tmp/repo/tfplan",
            ]
        );
    }

    #[test]
    fn terraform_import_command_uses_working_dir_and_resource_details() {
        let command = build_terraform_import_command(
            &test_context(),
            "aws_iam_role.instance",
            "loki-instance-role",
        );
        assert_eq!(command.program, "/usr/local/bin/terraform");
        assert_eq!(
            command.args,
            vec![
                "-chdir=/tmp/repo/deploy/terraform",
                "import",
                "-no-color",
                "aws_iam_role.instance",
                "loki-instance-role",
            ]
        );
    }

    #[test]
    fn resume_skips_only_completed_terraform_phases() {
        assert!(phase_is_past(
            InstallPhase::PlanDeployment,
            InstallPhase::PrepareDeployment
        ));
        assert!(phase_is_past(
            InstallPhase::PostInstall,
            InstallPhase::ApplyDeployment
        ));
        assert!(!phase_is_past(
            InstallPhase::ApplyDeployment,
            InstallPhase::ApplyDeployment
        ));
        assert!(!phase_is_past(
            InstallPhase::ApplyDeployment,
            InstallPhase::PostInstall
        ));
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

    #[test]
    fn parse_existing_resources_extracts_supported_resource_pairs() {
        let parsed = parse_existing_resources(
            r#"
Error: creating IAM Role (loki-instance-role): operation error IAM: CreateRole, https response error StatusCode: 409, RequestID: abc, EntityAlreadyExists: Role with name loki-instance-role already exists.

  with aws_iam_role.instance,
  on iam.tf line 10, in resource "aws_iam_role" "instance":
  10: resource "aws_iam_role" "instance" {

Error: creating IAM Instance Profile (loki-instance-profile): operation error IAM: CreateInstanceProfile, https response error StatusCode: 409, RequestID: def, EntityAlreadyExists: Instance Profile loki-instance-profile already exists.

  with module.compute.aws_iam_instance_profile.instance,
  on iam.tf line 20, in resource "aws_iam_instance_profile" "instance":

Error: creating S3 Bucket (loki-bucket): BucketAlreadyOwnedByYou: Bucket with name loki-bucket already exists.

  with aws_s3_bucket.artifacts,
  on s3.tf line 2, in resource "aws_s3_bucket" "artifacts":

Error: creating Security Group (sg-0123456789abcdef0): InvalidGroup.Duplicate: security group already exists.

  with aws_security_group.instance,
  on network.tf line 5, in resource "aws_security_group" "instance":

Error: creating VPC (vpc-0123456789abcdef0): operation error EC2: CreateVpc, https response error StatusCode: 400, RequestID: xyz, VpcLimitExceeded: The vpc vpc-0123456789abcdef0 already exists.

  with module.network.aws_vpc.main,
  on network.tf line 1, in resource "aws_vpc" "main":
"#,
        );

        assert_eq!(
            parsed,
            vec![
                ("aws_iam_role.instance".into(), "loki-instance-role".into()),
                (
                    "module.compute.aws_iam_instance_profile.instance".into(),
                    "loki-instance-profile".into(),
                ),
                ("aws_s3_bucket.artifacts".into(), "loki-bucket".into()),
                (
                    "aws_security_group.instance".into(),
                    "sg-0123456789abcdef0".into(),
                ),
                (
                    "module.network.aws_vpc.main".into(),
                    "vpc-0123456789abcdef0".into(),
                ),
            ]
        );
    }

    #[test]
    fn parse_existing_resources_ignores_unsupported_or_unmatched_errors() {
        let parsed = parse_existing_resources(
            r#"
Error: creating Subnet (subnet-0123456789abcdef0): operation error EC2: CreateSubnet, https response error StatusCode: 400, RequestID: xyz, InvalidSubnet.Conflict: subnet already exists.

  with aws_subnet.main,
  on network.tf line 30, in resource "aws_subnet" "main":

Error: reading IAM Role (loki-instance-role): some unrelated read error.

  with aws_iam_role.instance,
  on iam.tf line 10, in resource "aws_iam_role" "instance":
"#,
        );

        assert!(parsed.is_empty());
    }
}
