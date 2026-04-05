use crate::core::{DeployStatus, DoctorReport, InstallEvent, InstallEventSink, InstallSession};
use chrono::Utc;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::io::{self, Write};
use std::time::Instant;

pub fn print_human_line(for_agent: bool, line: impl AsRef<str>) -> io::Result<()> {
    if for_agent {
        let mut stderr = io::stderr().lock();
        writeln!(stderr, "{}", line.as_ref())
    } else {
        let mut stdout = io::stdout().lock();
        writeln!(stdout, "{}", line.as_ref())
    }
}

pub fn print_json_line(value: &Value) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, value)
        .map_err(|error| io::Error::other(error.to_string()))?;
    stdout.write_all(b"\n")
}

pub struct ForAgentEventSink<W: Write> {
    writer: W,
    current_step: Option<ActiveStep>,
}

struct ActiveStep {
    step_id: String,
    started_at: Instant,
    artifacts: BTreeMap<String, String>,
    message: Option<String>,
}

impl<W: Write> ForAgentEventSink<W> {
    pub fn new(writer: W) -> Self {
        Self {
            writer,
            current_step: None,
        }
    }

    pub fn emit_install_complete(
        &mut self,
        session: &InstallSession,
        total_duration_ms: u128,
    ) -> io::Result<()> {
        self.write_json(&json!({
            "event": "install_complete",
            "success": true,
            "session_id": session.session_id,
            "total_duration_ms": total_duration_ms as u64,
            "artifacts": summarize_install_artifacts(session),
        }))
    }

    pub fn emit_install_failed(
        &mut self,
        session_id: &str,
        error: &str,
        total_duration_ms: u128,
    ) -> io::Result<()> {
        let failed_step = self.current_step.as_ref().map(|step| step.step_id.clone());
        if let Some(step) = self.current_step.take() {
            self.write_json(&json!({
                "event": "step_failed",
                "step_id": step.step_id,
                "success": false,
                "error": error,
                "stderr": truncate_for_stderr(error),
                "duration_ms": step.started_at.elapsed().as_millis() as u64,
            }))?;
        }

        self.write_json(&json!({
            "event": "install_failed",
            "success": false,
            "failed_step": failed_step,
            "error": error,
            "session_id": session_id,
            "total_duration_ms": total_duration_ms as u64,
        }))
    }

    #[cfg(test)]
    pub fn into_inner(self) -> W {
        self.writer
    }
    fn write_json(&mut self, value: &Value) -> io::Result<()> {
        serde_json::to_writer(&mut self.writer, value)
            .map_err(|error| io::Error::other(error.to_string()))?;
        self.writer.write_all(b"\n")
    }
}

#[async_trait::async_trait]
impl<W> InstallEventSink for ForAgentEventSink<W>
where
    W: Write + Send,
{
    async fn emit(&mut self, event: InstallEvent) {
        let _ = self.handle_event(event);
    }
}

impl<W: Write> ForAgentEventSink<W> {
    fn handle_event(&mut self, event: InstallEvent) -> io::Result<()> {
        match event {
            InstallEvent::PhaseStarted { .. } => Ok(()),
            InstallEvent::StepStarted {
                step_id,
                display_name,
            } => {
                self.current_step = Some(ActiveStep {
                    step_id: step_id.clone(),
                    started_at: Instant::now(),
                    artifacts: BTreeMap::new(),
                    message: None,
                });
                self.write_json(&json!({
                    "event": "step_start",
                    "step_id": step_id,
                    "display_name": display_name,
                    "timestamp": Utc::now().to_rfc3339(),
                }))
            }
            InstallEvent::StepFinished { step_id, message } => {
                if let Some(step) = self.current_step.take() {
                    let mut payload = Map::new();
                    payload.insert("event".into(), Value::String("step_complete".into()));
                    payload.insert("step_id".into(), Value::String(step_id));
                    payload.insert("success".into(), Value::Bool(true));
                    payload.insert(
                        "duration_ms".into(),
                        Value::Number((step.started_at.elapsed().as_millis() as u64).into()),
                    );
                    let final_message = step.message.unwrap_or(message);
                    if !final_message.is_empty() && final_message != "completed" {
                        payload.insert("message".into(), Value::String(final_message));
                    }
                    if !step.artifacts.is_empty() {
                        payload.insert("artifacts".into(), json!(step.artifacts));
                    }
                    self.write_json(&Value::Object(payload))
                } else {
                    Ok(())
                }
            }
            InstallEvent::ArtifactRecorded { key, value } => {
                if let Some(step) = &mut self.current_step {
                    step.artifacts.insert(key, value);
                }
                Ok(())
            }
            InstallEvent::LogLine { message } => {
                if let Some(step) = &mut self.current_step {
                    step.message = Some(message);
                }
                Ok(())
            }
            InstallEvent::Warning { code, message } => self.write_json(&json!({
                "event": "warning",
                "code": code,
                "message": message,
                "timestamp": Utc::now().to_rfc3339(),
            })),
            InstallEvent::StackEvent {
                resource,
                status,
                resource_type,
            } => self.write_json(&json!({
                "event": "stack_event",
                "resource": resource,
                "status": status,
                "type": resource_type,
                "timestamp": Utc::now().to_rfc3339(),
            })),
        }
    }
}

pub fn doctor_result_json(report: &DoctorReport) -> Value {
    json!({
        "event": "doctor_result",
        "checks": report.checks.iter().map(|check| json!({
            "id": check.check.id,
            "passed": check.passed,
            "required": check.check.required,
            "message": check.message,
        })).collect::<Vec<_>>(),
        "all_required_passed": report.all_required_passed(),
    })
}

pub fn plan_result_json(plan: &crate::core::InstallPlan) -> Value {
    json!({
        "event": "plan_result",
        "pack": plan.resolved_pack.id,
        "profile": plan.resolved_profile.id,
        "method": plan.resolved_method.id.to_string(),
        "region": plan.resolved_region,
        "steps": plan.deploy_steps.iter().map(|step| json!({
            "id": step.id,
            "display_name": step.display_name,
        })).collect::<Vec<_>>(),
        "warnings": plan.warnings.iter().map(|warning| format!("{}: {}", warning.code, warning.message)).collect::<Vec<_>>(),
    })
}

pub fn status_result_json(session: &InstallSession, status: &DeployStatus) -> Value {
    json!({
        "event": "status_result",
        "deployed": status.deployed,
        "pack": status.pack,
        "profile": status.profile,
        "method": status.method.to_string(),
        "region": status.region,
        "stack_name": status.stack_name,
        "stack_status": status.stack_status,
        "instance_id": session.artifacts.get("instance_id"),
        "public_ip": session.artifacts.get("public_ip"),
        "last_updated": status.last_updated_at,
    })
}

fn summarize_install_artifacts(session: &InstallSession) -> Value {
    let mut artifacts = Map::new();
    for key in [
        "stack_name",
        "instance_id",
        "public_ip",
        "ssm_connect",
        "stack_status",
    ] {
        if let Some(value) = session.artifacts.get(key) {
            artifacts.insert(key.into(), Value::String(value.clone()));
        }
    }
    Value::Object(artifacts)
}

fn truncate_for_stderr(input: &str) -> String {
    input.chars().take(500).collect()
}

#[cfg(test)]
mod tests {
    use super::{ForAgentEventSink, doctor_result_json, plan_result_json, status_result_json};
    use crate::core::{
        DeployAction, DeployMethodId, DeployStatus, DeployStep, DoctorCheckResult, DoctorReport,
        InstallEvent, InstallEventSink, InstallMode, InstallPhase, InstallPlan, InstallRequest,
        InstallSession, InstallerEngine, MethodManifest, OptionValueType, PackManifest,
        PlanWarning, PostInstallStep, PrerequisiteCheck, PrerequisiteKind, ProfileManifest,
        SessionFormat, SessionPersistenceSpec,
    };
    use chrono::Utc;
    use serde_json::Value;
    use std::collections::BTreeMap;

    #[tokio::test]
    async fn for_agent_sink_emits_valid_jsonl() {
        let mut sink = ForAgentEventSink::new(Vec::new());
        sink.emit(InstallEvent::StepStarted {
            step_id: "validate-environment".into(),
            display_name: "Validate environment".into(),
        })
        .await;
        sink.emit(InstallEvent::ArtifactRecorded {
            key: "aws_account_id".into(),
            value: "123456789012".into(),
        })
        .await;
        sink.emit(InstallEvent::LogLine {
            message: "AWS identity validated".into(),
        })
        .await;
        sink.emit(InstallEvent::StackEvent {
            resource: "VPC".into(),
            status: "CREATE_COMPLETE".into(),
            resource_type: "AWS::EC2::VPC".into(),
        })
        .await;
        sink.emit(InstallEvent::StepFinished {
            step_id: "validate-environment".into(),
            message: "completed".into(),
        })
        .await;

        let output = String::from_utf8(sink.into_inner()).expect("utf8");
        for line in output.lines() {
            let _: Value = serde_json::from_str(line).expect("valid json line");
        }
    }

    #[test]
    fn structured_result_payloads_are_valid_json() {
        let report = DoctorReport {
            generated_at: Utc::now(),
            checks: vec![DoctorCheckResult {
                check: PrerequisiteCheck {
                    id: "os_supported".into(),
                    display_name: "Operating system supported".into(),
                    kind: PrerequisiteKind::OsSupported,
                    required: true,
                    remediation: None,
                },
                passed: true,
                message: "linux".into(),
            }],
        };

        let plan = InstallPlan {
            request: InstallRequest {
                engine: InstallerEngine::V2,
                mode: InstallMode::NonInteractive,
                pack: "openclaw".into(),
                profile: Some("builder".into()),
                method: Some(DeployMethodId::Cfn),
                region: Some("us-east-1".into()),
                stack_name: Some("loki-v2-test".into()),
                auto_yes: true,
                json_output: false,
                resume_session_id: None,
                extra_options: BTreeMap::new(),
            },
            resolved_pack: PackManifest {
                schema_version: 1,
                id: "openclaw".into(),
                display_name: "OpenClaw".into(),
                description: None,
                experimental: false,
                allowed_profiles: vec!["builder".into()],
                supported_methods: vec![DeployMethodId::Cfn],
                default_profile: Some("builder".into()),
                default_method: Some(DeployMethodId::Cfn),
                default_region: Some("us-east-1".into()),
                post_install: Vec::new(),
                required_env: Vec::new(),
                extra_options_schema: BTreeMap::new(),
            },
            resolved_profile: ProfileManifest {
                schema_version: 1,
                id: "builder".into(),
                display_name: "Builder".into(),
                description: None,
                supported_packs: vec!["openclaw".into()],
                default_method: Some(DeployMethodId::Cfn),
                default_region: Some("us-east-1".into()),
                config: BTreeMap::new(),
                tags: BTreeMap::new(),
            },
            resolved_method: MethodManifest {
                schema_version: 1,
                id: DeployMethodId::Cfn,
                display_name: "CloudFormation".into(),
                description: None,
                requires_stack_name: true,
                requires_region: true,
                required_tools: vec!["aws".into()],
                supports_resume: true,
                supports_uninstall: true,
                input_schema: BTreeMap::<String, crate::core::MethodOptionSpec>::from([(
                    "example".into(),
                    crate::core::MethodOptionSpec {
                        value_type: OptionValueType::String,
                        required: false,
                        default_value: None,
                        description: None,
                    },
                )]),
            },
            resolved_region: "us-east-1".into(),
            resolved_stack_name: Some("loki-v2-test".into()),
            prerequisites: Vec::new(),
            deploy_steps: vec![DeployStep {
                id: "validate-environment".into(),
                phase: InstallPhase::ValidateEnvironment,
                display_name: "Validate environment".into(),
                action: DeployAction::CreateStack,
            }],
            warnings: vec![PlanWarning {
                code: "experimental_pack".into(),
                message: "be careful".into(),
            }],
            post_install_steps: vec![PostInstallStep {
                id: "post".into(),
                display_name: "Post".into(),
                instruction: "Inspect outputs".into(),
            }],
            session_persistence: SessionPersistenceSpec {
                format: SessionFormat::Json,
                path_hint: "/tmp/session.json".into(),
                persist_phases: vec![InstallPhase::Finalize],
            },
            adapter_options: BTreeMap::new(),
        };

        let session = InstallSession {
            session_id: "session-1".into(),
            installer_version: "0.1.0".into(),
            engine: InstallerEngine::V2,
            mode: InstallMode::NonInteractive,
            request: plan.request.clone(),
            plan: Some(plan.clone()),
            phase: InstallPhase::PostInstall,
            started_at: Utc::now(),
            updated_at: Utc::now(),
            artifacts: BTreeMap::from([
                ("instance_id".into(), "i-123".into()),
                ("public_ip".into(), "1.2.3.4".into()),
            ]),
            status_summary: None,
        };
        let status = DeployStatus {
            deployed: true,
            pack: "openclaw".into(),
            profile: "builder".into(),
            method: DeployMethodId::Cfn,
            region: Some("us-east-1".into()),
            stack_name: Some("loki-v2-test".into()),
            stack_status: Some("CREATE_COMPLETE".into()),
            instance_health: None,
            last_updated_at: Utc::now(),
        };

        for value in [
            doctor_result_json(&report),
            plan_result_json(&plan),
            status_result_json(&session, &status),
        ] {
            let line = serde_json::to_string(&value).expect("serialize");
            let _: Value = serde_json::from_str(&line).expect("valid json");
        }
    }
}
