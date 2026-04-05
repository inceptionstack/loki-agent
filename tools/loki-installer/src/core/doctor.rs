//! Lightweight environment checks surfaced by the doctor command and TUI.

use crate::core::{InstallRequest, MethodManifest, PrerequisiteCheck, PrerequisiteKind};
use chrono::{DateTime, Utc};

#[derive(Debug, Clone)]
pub struct DoctorCheckResult {
    pub check: PrerequisiteCheck,
    pub passed: bool,
    pub message: String,
}

#[derive(Debug, Clone)]
pub struct DoctorReport {
    pub generated_at: DateTime<Utc>,
    pub checks: Vec<DoctorCheckResult>,
}

impl DoctorReport {
    pub fn all_required_passed(&self) -> bool {
        self.checks
            .iter()
            .all(|check| !check.check.required || check.passed)
    }
}

pub fn run_doctor(
    request: Option<&InstallRequest>,
    method: Option<&MethodManifest>,
) -> DoctorReport {
    let os = std::env::consts::OS;
    let arch = std::env::consts::ARCH;
    let aws_present = command_exists("aws");
    let credentials_present = [
        "AWS_PROFILE",
        "AWS_ACCESS_KEY_ID",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
    ]
    .iter()
    .any(|key| std::env::var(key).is_ok());
    let network_hint = std::env::var("LOKI_INSTALLER_OFFLINE").is_err();

    let mut checks = vec![
        DoctorCheckResult {
            check: PrerequisiteCheck {
                id: "os_supported".into(),
                display_name: "Operating system supported".into(),
                kind: PrerequisiteKind::OsSupported,
                required: true,
                remediation: Some("Use linux or darwin for Installer V2.".into()),
            },
            passed: matches!(os, "linux" | "macos"),
            message: format!("detected OS: {os}"),
        },
        DoctorCheckResult {
            check: PrerequisiteCheck {
                id: "arch_supported".into(),
                display_name: "Architecture supported".into(),
                kind: PrerequisiteKind::ArchSupported,
                required: true,
                remediation: Some("Use amd64/x86_64 or arm64/aarch64.".into()),
            },
            passed: matches!(arch, "x86_64" | "aarch64"),
            message: format!("detected architecture: {arch}"),
        },
        DoctorCheckResult {
            check: PrerequisiteCheck {
                id: "aws_cli_present".into(),
                display_name: "AWS CLI present".into(),
                kind: PrerequisiteKind::AwsCliPresent,
                required: true,
                remediation: Some("Install awscli v2 and ensure it is on PATH.".into()),
            },
            passed: aws_present,
            message: if aws_present {
                "aws found on PATH".into()
            } else {
                "aws not found on PATH".into()
            },
        },
        DoctorCheckResult {
            check: PrerequisiteCheck {
                id: "aws_credentials_hint".into(),
                display_name: "AWS credentials hint available".into(),
                kind: PrerequisiteKind::AwsCredentialsValid,
                required: false,
                remediation: Some("Set AWS_PROFILE or AWS_ACCESS_KEY_ID before install.".into()),
            },
            passed: credentials_present,
            message: if credentials_present {
                "AWS credential environment hints detected".into()
            } else {
                "No AWS credential environment hints detected".into()
            },
        },
        DoctorCheckResult {
            check: PrerequisiteCheck {
                id: "network_reachable".into(),
                display_name: "Network reachability hint".into(),
                kind: PrerequisiteKind::NetworkReachable,
                required: false,
                remediation: Some(
                    "Unset LOKI_INSTALLER_OFFLINE when network access is available.".into(),
                ),
            },
            passed: network_hint,
            message: if network_hint {
                "Network checks not disabled".into()
            } else {
                "Offline mode hint present".into()
            },
        },
    ];

    if let Some(method) = method {
        for tool in &method.required_tools {
            checks.push(DoctorCheckResult {
                check: PrerequisiteCheck {
                    id: format!("tool_{tool}"),
                    display_name: format!("{tool} present"),
                    kind: PrerequisiteKind::MethodToolingPresent,
                    required: true,
                    remediation: Some(format!("Install {tool} and ensure it is on PATH.")),
                },
                passed: command_exists(tool),
                message: format!("required by method {}", method.id),
            });
        }
    }

    if let Some(request) = request {
        checks.push(DoctorCheckResult {
            check: PrerequisiteCheck {
                id: "request_mode".into(),
                display_name: "Request mode resolved".into(),
                kind: PrerequisiteKind::BinaryDownloadable,
                required: false,
                remediation: None,
            },
            passed: true,
            message: format!("mode: {:?}", request.mode),
        });
    }

    DoctorReport {
        generated_at: Utc::now(),
        checks,
    }
}

fn command_exists(program: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|path| path.join(program).exists()))
        .unwrap_or(false)
}
