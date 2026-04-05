//! Install plan generation, validation, and adapter dispatch.

use crate::adapters::{NoopEventSink, adapter_for_method};
use crate::core::doctor::{DoctorReport, RepoAvailabilityCheck, run_doctor};
use crate::core::manifests::{ManifestError, ManifestRepository};
use crate::core::session::{create_session, persist_session, session_path_for, session_path_hint};
use crate::core::{
    AdapterError, AdapterValidationError, DeployMethodId, InstallMode, InstallPhase, InstallPlan,
    InstallRequest, InstallSession, MethodManifest, MethodOptionSpec, OptionValueType,
    PackManifest, PackOptionSpec, PlanWarning, PostInstallActionId, PostInstallStep,
    ProfileManifest, SessionFormat, SessionPersistenceSpec,
};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug, thiserror::Error)]
pub enum PlannerError {
    #[error("{0}")]
    Message(String),
    #[error(transparent)]
    Manifest(#[from] ManifestError),
    #[error(transparent)]
    Adapter(#[from] AdapterError),
}

#[derive(Clone)]
pub struct Planner {
    repo: ManifestRepository,
}

impl Planner {
    pub fn discover() -> Result<Self, PlannerError> {
        Ok(Self {
            repo: ManifestRepository::discover()?,
        })
    }

    pub fn from_repo_root(root: impl AsRef<Path>) -> Result<Self, PlannerError> {
        Ok(Self {
            repo: ManifestRepository::from_root(root.as_ref().to_path_buf())?,
        })
    }

    pub fn repo(&self) -> &ManifestRepository {
        &self.repo
    }

    pub async fn build_plan(&self, request: InstallRequest) -> Result<InstallPlan, PlannerError> {
        request.validate_contract().map_err(PlannerError::Message)?;
        let pack = self.repo.load_pack(&request.pack)?;
        pack.validate_contract().map_err(PlannerError::Message)?;
        let profile = self.resolve_profile(&request, &pack)?;
        profile.validate_contract().map_err(PlannerError::Message)?;
        let method = self.resolve_method(&request, &pack, &profile)?;
        method.validate_contract().map_err(PlannerError::Message)?;
        let region = self.resolve_region(&request, &pack, &profile, &method)?;
        let stack_name = self.resolve_stack_name(&request, &pack, &method)?;
        let adapter_options = self.resolve_adapter_options(&request, &pack, &method)?;

        let adapter = adapter_for_method(method.id);
        debug_assert_eq!(adapter.method_id(), method.id);
        adapter
            .validate_request(&request, &pack, Some(&profile), &method)
            .map_err(|err| PlannerError::Message(err.to_string()))?;
        let adapter_plan = adapter
            .build_plan(&request, &pack, &profile, &method)
            .await?;

        let warnings = self.collect_warnings(&pack, &profile, &method, &request, &region);
        let path_hint = {
            let session = create_session(request.clone(), None);
            let path =
                session_path_for(&session).map_err(|err| PlannerError::Message(err.to_string()))?;
            session_path_hint(&path)
        };

        let plan = InstallPlan {
            request,
            resolved_pack: pack.clone(),
            resolved_profile: profile.clone(),
            resolved_method: method.clone(),
            resolved_region: region,
            resolved_stack_name: stack_name,
            prerequisites: adapter_plan.prerequisites,
            deploy_steps: adapter_plan.deploy_steps,
            warnings: [warnings, adapter_plan.warnings].concat(),
            post_install_steps: if adapter_plan.post_install_steps.is_empty() {
                post_install_steps_for_pack(&pack)
            } else {
                adapter_plan.post_install_steps
            },
            session_persistence: SessionPersistenceSpec {
                format: SessionFormat::Json,
                path_hint,
                persist_phases: vec![
                    InstallPhase::PlanDeployment,
                    InstallPhase::ApplyDeployment,
                    InstallPhase::WaitForResources,
                    InstallPhase::Finalize,
                    InstallPhase::PostInstall,
                ],
            },
            adapter_options: merge_adapter_options(
                BTreeMap::from([("repo_root".into(), self.repo.root().display().to_string())]),
                merge_adapter_options(adapter_options, adapter_plan.adapter_options),
            ),
        };
        plan.validate_contract().map_err(PlannerError::Message)?;

        Ok(plan)
    }

    pub fn run_doctor(
        &self,
        request: Option<&InstallRequest>,
        repo_availability: RepoAvailabilityCheck,
    ) -> Result<DoctorReport, PlannerError> {
        let method = request
            .and_then(|req| req.method)
            .map(|method| self.repo.load_method(method))
            .transpose()?;
        Ok(run_doctor(request, method.as_ref(), repo_availability))
    }

    pub async fn start_install(&self, plan: InstallPlan) -> Result<InstallSession, PlannerError> {
        let mut sink = NoopEventSink::default();
        self.start_install_with_sink(plan, &mut sink).await
    }

    pub async fn start_install_with_sink(
        &self,
        plan: InstallPlan,
        sink: &mut dyn crate::core::InstallEventSink,
    ) -> Result<InstallSession, PlannerError> {
        let mut session = self.create_install_session(plan)?;
        self.execute_install_with_sink(&mut session, sink).await?;
        Ok(session)
    }

    pub fn create_install_session(
        &self,
        plan: InstallPlan,
    ) -> Result<InstallSession, PlannerError> {
        let session = create_session(plan.request.clone(), Some(plan));
        persist_session(&session).map_err(|err| PlannerError::Message(err.to_string()))?;
        Ok(session)
    }

    pub async fn execute_install_with_sink(
        &self,
        session: &mut InstallSession,
        sink: &mut dyn crate::core::InstallEventSink,
    ) -> Result<(), PlannerError> {
        let plan = session
            .plan
            .clone()
            .ok_or_else(|| PlannerError::Message("session missing install plan".into()))?;
        let adapter = adapter_for_method(plan.resolved_method.id);
        persist_session(session).map_err(|err| PlannerError::Message(err.to_string()))?;
        let result = adapter.apply(&plan, session, sink).await?;
        session.phase = result.final_phase;
        session.artifacts.extend(result.artifacts);
        session.status_summary = Some("deployment completed".into());
        persist_session(session).map_err(|err| PlannerError::Message(err.to_string()))?;
        Ok(())
    }

    pub async fn resume_install(&self, session: &mut InstallSession) -> Result<(), PlannerError> {
        let mut sink = NoopEventSink::default();
        self.resume_install_with_sink(session, &mut sink).await
    }

    pub async fn resume_install_with_sink(
        &self,
        session: &mut InstallSession,
        sink: &mut dyn crate::core::InstallEventSink,
    ) -> Result<(), PlannerError> {
        let method = session
            .plan
            .as_ref()
            .map(|plan| plan.resolved_method.id)
            .or(session.request.method)
            .ok_or_else(|| PlannerError::Message("session missing deployment method".into()))?;
        let adapter = adapter_for_method(method);
        let result = adapter.resume(session, sink).await?;
        session.phase = result.final_phase;
        session.artifacts.extend(result.artifacts);
        session.status_summary = Some("deployment resumed".into());
        persist_session(session).map_err(|err| PlannerError::Message(err.to_string()))?;
        Ok(())
    }

    pub async fn uninstall(&self, session: &InstallSession) -> Result<(), PlannerError> {
        let mut sink = NoopEventSink::default();
        self.uninstall_with_sink(session, &mut sink).await
    }

    pub async fn uninstall_with_sink(
        &self,
        session: &InstallSession,
        sink: &mut dyn crate::core::InstallEventSink,
    ) -> Result<(), PlannerError> {
        let method = session
            .plan
            .as_ref()
            .map(|plan| plan.resolved_method.id)
            .or(session.request.method)
            .ok_or_else(|| PlannerError::Message("session missing deployment method".into()))?;
        let adapter = adapter_for_method(method);
        adapter.uninstall(session, sink).await?;
        Ok(())
    }

    pub async fn status(
        &self,
        session: &InstallSession,
    ) -> Result<crate::core::DeployStatus, PlannerError> {
        let method = session
            .plan
            .as_ref()
            .map(|plan| plan.resolved_method.id)
            .or(session.request.method)
            .ok_or_else(|| PlannerError::Message("session missing deployment method".into()))?;
        let adapter = adapter_for_method(method);
        Ok(adapter.status(session).await?)
    }

    pub fn attach_repo_root(&self, session: &mut InstallSession) {
        if let Some(plan) = &mut session.plan {
            plan.adapter_options
                .entry("repo_root".into())
                .or_insert_with(|| self.repo.root().display().to_string());
        }
    }

    fn resolve_profile(
        &self,
        request: &InstallRequest,
        pack: &PackManifest,
    ) -> Result<ProfileManifest, PlannerError> {
        let profile_id = request
            .profile
            .clone()
            .or_else(|| pack.default_profile.clone())
            .ok_or_else(|| PlannerError::Message("profile is required for planning".into()))?;
        if !pack.allowed_profiles.contains(&profile_id) {
            return Err(PlannerError::Message(format!(
                "profile {profile_id} is not allowed for pack {}",
                pack.id
            )));
        }
        let profile = self.repo.load_profile(&profile_id)?;
        if !profile.supported_packs.contains(&pack.id) {
            return Err(PlannerError::Message(format!(
                "profile {profile_id} does not support pack {}",
                pack.id
            )));
        }
        Ok(profile)
    }

    fn resolve_method(
        &self,
        request: &InstallRequest,
        pack: &PackManifest,
        profile: &ProfileManifest,
    ) -> Result<MethodManifest, PlannerError> {
        let method_id = request
            .method
            .or(profile.default_method)
            .or(pack.default_method)
            .ok_or_else(|| PlannerError::Message("method is required for planning".into()))?;
        if !pack.supported_methods.contains(&method_id) {
            return Err(PlannerError::Message(format!(
                "method {method_id} is not supported by pack {}",
                pack.id
            )));
        }
        Ok(self.repo.load_method(method_id)?)
    }

    fn resolve_region(
        &self,
        request: &InstallRequest,
        pack: &PackManifest,
        profile: &ProfileManifest,
        method: &MethodManifest,
    ) -> Result<String, PlannerError> {
        if !method.requires_region {
            return Ok(request
                .region
                .clone()
                .or_else(|| profile.default_region.clone())
                .or_else(|| pack.default_region.clone())
                .unwrap_or_else(|| "us-east-1".into()));
        }

        request
            .region
            .clone()
            .or_else(|| profile.default_region.clone())
            .or_else(|| pack.default_region.clone())
            .or_else(|| std::env::var("AWS_REGION").ok())
            .or_else(|| std::env::var("AWS_DEFAULT_REGION").ok())
            .ok_or_else(|| PlannerError::Message("region is required for planning".into()))
    }

    fn resolve_stack_name(
        &self,
        request: &InstallRequest,
        pack: &PackManifest,
        method: &MethodManifest,
    ) -> Result<Option<String>, PlannerError> {
        let stack_name = request.stack_name.clone().or_else(|| {
            method
                .requires_stack_name
                .then(|| format!("loki-{}", pack.id))
        });
        if method.requires_stack_name && stack_name.is_none() {
            return Err(PlannerError::Message("stack name is required".into()));
        }
        Ok(stack_name)
    }

    fn resolve_adapter_options(
        &self,
        request: &InstallRequest,
        pack: &PackManifest,
        method: &MethodManifest,
    ) -> Result<BTreeMap<String, String>, PlannerError> {
        let mut resolved = BTreeMap::new();

        for (key, spec) in &pack.extra_options_schema {
            if let Some(value) = resolve_option_value(key, spec, request.extra_options.get(key))? {
                resolved.insert(key.clone(), value);
            }
        }

        for (key, spec) in &method.input_schema {
            if let Some(value) = resolve_option_value(key, spec, request.extra_options.get(key))? {
                resolved.insert(key.clone(), value);
            }
        }

        for key in request.extra_options.keys() {
            if !pack.extra_options_schema.contains_key(key)
                && !method.input_schema.contains_key(key)
            {
                return Err(PlannerError::Message(
                    AdapterValidationError::InvalidOption(key.clone()).to_string(),
                ));
            }
        }

        Ok(resolved)
    }

    fn collect_warnings(
        &self,
        pack: &PackManifest,
        profile: &ProfileManifest,
        method: &MethodManifest,
        request: &InstallRequest,
        region: &str,
    ) -> Vec<PlanWarning> {
        let mut warnings = Vec::new();
        if pack.experimental {
            warnings.push(PlanWarning {
                code: "experimental_pack".into(),
                message: format!("pack {} is marked experimental", pack.id),
            });
        }
        if request.mode == InstallMode::NonInteractive && !request.auto_yes {
            warnings.push(PlanWarning {
                code: "headless_without_yes".into(),
                message: "non-interactive execution without --yes may fail on future prompts"
                    .into(),
            });
        }
        if method.id == DeployMethodId::Terraform && region != "us-east-1" {
            warnings.push(PlanWarning {
                code: "terraform_region_override".into(),
                message: format!("terraform deployment will target region {region}"),
            });
        }
        if profile.id == "personal_assistant" && pack.id != "nemoclaw" {
            warnings.push(PlanWarning {
                code: "restricted_profile".into(),
                message: "personal_assistant is least-privileged and may limit pack capabilities"
                    .into(),
            });
        }
        warnings
    }
}

fn merge_adapter_options(
    mut resolved_options: BTreeMap<String, String>,
    adapter_options: BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    resolved_options.extend(adapter_options);
    resolved_options
}

fn resolve_option_value<T>(
    key: &str,
    spec: &T,
    explicit: Option<&String>,
) -> Result<Option<String>, PlannerError>
where
    T: OptionSpec,
{
    let value = explicit.cloned().or_else(|| spec.default_value().cloned());
    let Some(value) = value else {
        if spec.required() {
            return Err(PlannerError::Message(
                AdapterValidationError::InvalidOption(format!("missing required option {key}"))
                    .to_string(),
            ));
        }
        return Ok(None);
    };
    validate_option_value(key, spec.value_type(), &value)?;
    Ok(Some(value))
}

fn validate_option_value(
    key: &str,
    value_type: OptionValueType,
    value: &str,
) -> Result<(), PlannerError> {
    let valid = match value_type {
        OptionValueType::String => true,
        OptionValueType::Integer => value.parse::<i64>().is_ok(),
        OptionValueType::Boolean => matches!(value, "true" | "false"),
    };

    if valid {
        Ok(())
    } else {
        Err(PlannerError::Message(format!(
            "invalid value for option {key}: expected {value_type:?}"
        )))
    }
}

trait OptionSpec {
    fn required(&self) -> bool;
    fn default_value(&self) -> Option<&String>;
    fn value_type(&self) -> OptionValueType;
}

impl OptionSpec for PackOptionSpec {
    fn required(&self) -> bool {
        self.required
    }

    fn default_value(&self) -> Option<&String> {
        self.default_value.as_ref()
    }

    fn value_type(&self) -> OptionValueType {
        self.value_type
    }
}

impl OptionSpec for MethodOptionSpec {
    fn required(&self) -> bool {
        self.required
    }

    fn default_value(&self) -> Option<&String> {
        self.default_value.as_ref()
    }

    fn value_type(&self) -> OptionValueType {
        self.value_type
    }
}

pub fn post_install_steps_for_pack(pack: &PackManifest) -> Vec<PostInstallStep> {
    let mut steps = Vec::new();
    for action in &pack.post_install {
        match action {
            PostInstallActionId::SsmSession => steps.push(PostInstallStep {
                id: "ssm_session".into(),
                display_name: "Start SSM session".into(),
                instruction: "aws ssm start-session --target <instance-id>".into(),
            }),
            PostInstallActionId::Pairing => steps.push(PostInstallStep {
                id: "pairing".into(),
                display_name: "Complete agent pairing".into(),
                instruction: "Follow the pack-specific pairing instructions after first login."
                    .into(),
            }),
        }
    }
    steps
}
