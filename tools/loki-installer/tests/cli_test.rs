use clap::Parser;
use loki_installer::cli::args::{Cli, Command, MethodArg};

#[test]
fn parses_install_subcommand() {
    let cli = Cli::try_parse_from([
        "loki-installer",
        "install",
        "--pack",
        "openclaw",
        "--profile",
        "builder",
        "--method",
        "cfn",
        "--yes",
        "--non-interactive",
    ])
    .expect("parse install");

    let Command::Install(args) = cli.command else {
        panic!("expected install");
    };

    assert_eq!(args.pack.as_deref(), Some("openclaw"));
    assert_eq!(args.method, Some(MethodArg::Cfn));
}

#[test]
fn parses_doctor_subcommand() {
    let cli = Cli::try_parse_from(["loki-installer", "doctor", "--json"]).expect("parse doctor");
    assert!(matches!(cli.command, Command::Doctor(_)));
}

#[test]
fn parses_plan_subcommand() {
    let cli = Cli::try_parse_from([
        "loki-installer",
        "plan",
        "--pack",
        "openclaw",
        "--method",
        "terraform",
        "--yes",
        "--non-interactive",
    ])
    .expect("parse plan");
    assert!(matches!(cli.command, Command::Plan(_)));
}

#[test]
fn parses_resume_subcommand() {
    let cli = Cli::try_parse_from(["loki-installer", "resume", "--session", "abc123"])
        .expect("parse resume");
    assert!(matches!(cli.command, Command::Resume(_)));
}

#[test]
fn parses_uninstall_subcommand() {
    let cli = Cli::try_parse_from(["loki-installer", "uninstall", "--session", "abc123"])
        .expect("parse uninstall");
    assert!(matches!(cli.command, Command::Uninstall(_)));
}

#[test]
fn parses_status_subcommand() {
    let cli = Cli::try_parse_from(["loki-installer", "status", "--session", "abc123"])
        .expect("parse status");
    assert!(matches!(cli.command, Command::Status(_)));
}
