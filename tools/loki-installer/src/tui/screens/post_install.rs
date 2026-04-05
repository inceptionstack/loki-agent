//! Post-install summary screen content.

use crate::tui::app::AppState;
use ratatui::{
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
};

pub fn content(state: &AppState) -> Text<'static> {
    let Some(session) = &state.session else {
        return Text::from(vec![
            Line::from(vec![Span::styled(
                "Installation complete!",
                Style::default()
                    .fg(Color::Green)
                    .add_modifier(Modifier::BOLD),
            )]),
            Line::from(""),
            Line::from("Deployment session saved."),
            Line::from(""),
            Line::from("Press q to exit"),
        ]);
    };

    let stack_name = session
        .plan
        .as_ref()
        .and_then(|plan| plan.resolved_stack_name.clone())
        .or_else(|| session.artifacts.get("stack_name").cloned())
        .or_else(|| session.request.stack_name.clone())
        .unwrap_or_else(|| "<environment_name>".into());
    let region = session
        .plan
        .as_ref()
        .map(|plan| plan.resolved_region.clone())
        .or_else(|| session.request.region.clone())
        .unwrap_or_else(|| "<region>".into());
    let _public_ip = session
        .artifacts
        .get("public_ip")
        .cloned()
        .unwrap_or_else(|| "<instance_ip>".into());
    let instance_id = session.artifacts.get("instance_id").cloned();

    let mut lines = vec![
        Line::from(vec![
            Span::styled(
                "✓ ",
                Style::default()
                    .fg(Color::Green)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                "Installation complete!",
                Style::default()
                    .fg(Color::Green)
                    .add_modifier(Modifier::BOLD),
            ),
        ]),
        label_value_line("Session: ", &session.session_id),
        label_value_line("Stack: ", &stack_name),
        label_value_line("Region: ", &region),
    ];

    if let Some(ref instance_id) = instance_id {
        lines.push(label_value_line("Instance: ", instance_id));
    }

    lines.extend([
        Line::from(""),
        Line::from(vec![Span::styled(
            "What to do next:",
            Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        )]),
        Line::from(vec![Span::styled(
            "1. Connect to your instance via SSM:",
            Style::default().fg(Color::Cyan),
        )]),
        command_line(format!(
            "   aws ssm start-session --target {} --region {region}",
            instance_id.as_deref().unwrap_or("<instance-id>")
        )),
        Line::from(vec![Span::styled(
            "2. Set your Telegram bot token:",
            Style::default().fg(Color::Cyan),
        )]),
        command_line("   openclaw config set telegram.token <YOUR_BOT_TOKEN>"),
        command_line("   openclaw config set telegram.allowed_chat_ids <YOUR_CHAT_ID>"),
        Line::from(vec![Span::styled(
            "3. Restart the agent:",
            Style::default().fg(Color::Cyan),
        )]),
        command_line("   sudo systemctl restart openclaw"),
        Line::from(vec![Span::styled(
            "4. Verify it's running:",
            Style::default().fg(Color::Cyan),
        )]),
        command_line("   openclaw status"),
        Line::from(""),
        Line::from(vec![
            Span::styled("For help: ", Style::default().fg(Color::Cyan)),
            Span::styled(
                "https://docs.openclaw.ai/getting-started",
                Style::default().fg(Color::DarkGray),
            ),
        ]),
        Line::from("Press q to exit"),
    ]);

    Text::from(lines)
}

fn label_value_line(label: &str, value: &str) -> Line<'static> {
    Line::from(vec![
        Span::styled(label.to_string(), Style::default().fg(Color::Cyan)),
        Span::raw(value.to_string()),
    ])
}

fn command_line(command: impl Into<String>) -> Line<'static> {
    Line::from(vec![Span::styled(
        command.into(),
        Style::default().fg(Color::Yellow),
    )])
}

#[cfg(test)]
mod tests {
    use super::content;
    use crate::core::{
        DeployMethodId, InstallMode, InstallPhase, InstallPlan, InstallRequest, InstallSession,
        InstallerEngine, MethodManifest, PackManifest, ProfileManifest, SessionFormat,
        SessionPersistenceSpec,
    };
    use crate::tui::app::AppState;
    use chrono::Utc;
    use std::collections::BTreeMap;

    #[test]
    fn post_install_content_uses_artifacts_and_fallbacks() {
        let mut state = AppState::default();
        state.session = Some(InstallSession {
            session_id: "session-123".into(),
            installer_version: "test".into(),
            engine: InstallerEngine::V2,
            mode: InstallMode::Interactive,
            request: InstallRequest {
                engine: InstallerEngine::V2,
                mode: InstallMode::Interactive,
                pack: "openclaw".into(),
                profile: Some("builder".into()),
                method: Some(DeployMethodId::Terraform),
                region: Some("us-east-1".into()),
                stack_name: Some("fallback-stack".into()),
                auto_yes: true,
                json_output: false,
                resume_session_id: None,
                extra_options: BTreeMap::new(),
            },
            plan: Some(sample_plan()),
            phase: InstallPhase::PostInstall,
            started_at: Utc::now(),
            updated_at: Utc::now(),
            artifacts: BTreeMap::from([
                ("instance_id".into(), "i-123".into()),
                ("public_ip".into(), "1.2.3.4".into()),
            ]),
            status_summary: Some("deployment completed".into()),
        });

        let text = content(&state);
        let rendered = text
            .lines
            .iter()
            .map(|line| line.to_string())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(rendered.contains("Installation complete!"));
        assert!(rendered.contains("Session: session-123"));
        assert!(rendered.contains("Stack: loki-openclaw"));
        assert!(rendered.contains("Region: us-east-1"));
        assert!(rendered.contains("Instance: i-123"));
        assert!(rendered.contains("aws ssm start-session --target i-123 --region us-east-1"));
        assert!(rendered.contains("https://docs.openclaw.ai/getting-started"));
        assert!(rendered.contains("Press q to exit"));
    }

    fn sample_plan() -> InstallPlan {
        InstallPlan {
            request: InstallRequest {
                engine: InstallerEngine::V2,
                mode: InstallMode::Interactive,
                pack: "openclaw".into(),
                profile: Some("builder".into()),
                method: Some(DeployMethodId::Terraform),
                region: Some("us-east-1".into()),
                stack_name: Some("loki-openclaw".into()),
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
                supported_methods: vec![DeployMethodId::Terraform],
                default_profile: Some("builder".into()),
                default_method: Some(DeployMethodId::Terraform),
                default_region: Some("us-east-1".into()),
                post_install: vec![],
                required_env: vec![],
                extra_options_schema: BTreeMap::new(),
            },
            resolved_profile: ProfileManifest {
                schema_version: 1,
                id: "builder".into(),
                display_name: "Builder".into(),
                description: None,
                supported_packs: vec!["openclaw".into()],
                default_method: Some(DeployMethodId::Terraform),
                default_region: Some("us-east-1".into()),
                config: BTreeMap::new(),
                tags: BTreeMap::new(),
            },
            resolved_method: MethodManifest {
                schema_version: 1,
                id: DeployMethodId::Terraform,
                display_name: "Terraform".into(),
                description: None,
                requires_stack_name: true,
                requires_region: true,
                required_tools: vec!["terraform".into()],
                supports_resume: true,
                supports_uninstall: true,
                input_schema: BTreeMap::new(),
            },
            resolved_region: "us-east-1".into(),
            resolved_stack_name: Some("loki-openclaw".into()),
            prerequisites: vec![],
            deploy_steps: vec![],
            warnings: vec![],
            post_install_steps: vec![],
            session_persistence: SessionPersistenceSpec {
                format: SessionFormat::Json,
                path_hint: "session.json".into(),
                persist_phases: vec![InstallPhase::PostInstall],
            },
            adapter_options: BTreeMap::new(),
        }
    }
}
