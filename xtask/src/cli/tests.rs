//! Unit tests of the parent module, against the fixture workspace and the fixture models.

use std::io::{self, Write};
use std::process::ExitCode;

use super::main;

/// A writer whose device is gone.
struct Broken;

impl Write for Broken {
    fn write(&mut self, _buffer: &[u8]) -> io::Result<usize> {
        Err(io::Error::other("closed"))
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/arch");

fn fixture(path: &str) -> String {
    format!("{FIXTURES}/{path}")
}

struct Run {
    code: ExitCode,
    stdout: String,
    stderr: String,
}

fn run(args: &[&str]) -> Run {
    let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
    let code = main(args.iter().copied().chain(None), &mut stdout, &mut stderr);
    Run {
        code,
        stdout: String::from_utf8(stdout).unwrap(),
        stderr: String::from_utf8(stderr).unwrap(),
    }
}

/// The arguments of `arch` against the fixture workspace with the given model.
fn arch<'a>(model: &'a str, workspace: &'a str) -> [&'a str; 6] {
    [
        "xtask",
        "arch",
        "--config",
        model,
        "--manifest-path",
        workspace,
    ]
}

#[test]
fn violations_exit_with_status_one_and_are_printed_to_stdout() {
    let (model, workspace) = (fixture("valid.toml"), fixture("workspace/Cargo.toml"));

    let run = run(&arch(&model, &workspace));

    assert_eq!(run.code, ExitCode::FAILURE);
    assert!(
        run.stdout.contains("error[arch::layer]: `shop-domain`"),
        "{}",
        run.stdout
    );
    assert!(run.stdout.ends_with("layer(s) checked\n"), "{}", run.stdout);
    assert!(!run.stdout.contains("::error"), "{}", run.stdout);
    assert_eq!(run.stderr, "");
}

#[test]
fn the_github_actions_flag_adds_the_annotations() {
    let (model, workspace) = (fixture("valid.toml"), fixture("workspace/Cargo.toml"));
    let mut args = arch(&model, &workspace).to_vec();
    args.push("--github-actions");

    let run = run(&args);

    assert_eq!(run.code, ExitCode::FAILURE);
    assert_eq!(
        run.stdout.matches("\n::error file=").count(),
        5,
        "{}",
        run.stdout
    );
}

#[test]
fn an_invalid_model_exits_with_status_two_and_says_why_on_stderr() {
    let (model, workspace) = (fixture("invalid.toml"), fixture("workspace/Cargo.toml"));

    let run = run(&arch(&model, &workspace));

    assert_eq!(run.code, ExitCode::from(2));
    assert_eq!(run.stdout, "");
    assert!(
        run.stderr
            .starts_with("architecture check could not run: invalid "),
        "{}",
        run.stderr
    );
    assert!(
        run.stderr.ends_with("unknown key `typo` in [[layer]]\n"),
        "{}",
        run.stderr
    );
}

#[test]
fn a_missing_workspace_exits_with_status_two_and_says_why_on_stderr() {
    let (model, workspace) = (
        fixture("valid.toml"),
        fixture("no-such-workspace/Cargo.toml"),
    );

    let run = run(&arch(&model, &workspace));

    assert_eq!(run.code, ExitCode::from(2));
    assert_eq!(run.stdout, "");
    assert!(
        run.stderr
            .starts_with("architecture check could not run: cannot read the workspace: "),
        "{}",
        run.stderr
    );
    assert!(
        run.stderr.ends_with('\n') && !run.stderr.ends_with("\n\n"),
        "{:?}",
        run.stderr
    );
}

#[test]
fn a_missing_model_exits_with_status_two() {
    let workspace = fixture("workspace/Cargo.toml");

    let run = run(&arch("no-such-model.toml", &workspace));

    assert_eq!(run.code, ExitCode::from(2));
    assert!(
        run.stderr
            .starts_with("architecture check could not run: cannot read no-such-model.toml: "),
        "{}",
        run.stderr
    );
}

#[test]
fn no_command_prints_the_usage_on_stderr_and_exits_with_status_two() {
    for args in [
        &["xtask"][..],
        &["xtask", "fmt"],
        &["xtask", "arch", "--config"],
        &["xtask", "arch", "--bogus", "x"],
    ] {
        let run = run(args);

        assert_eq!(run.code, ExitCode::from(2), "{args:?}");
        assert_eq!(run.stdout, "", "{args:?}");
        assert!(
            run.stderr.starts_with("error: ") || run.stderr.contains("Usage: xtask <COMMAND>"),
            "{args:?}: {}",
            run.stderr
        );
    }
}

#[test]
fn help_and_version_are_printed_on_stdout_and_exit_with_status_zero() {
    let help = run(&["xtask", "--help"]);
    let arch_help = run(&["xtask", "arch", "--help"]);
    let version = run(&["xtask", "--version"]);

    for run in [&help, &arch_help, &version] {
        assert_eq!(run.code, ExitCode::SUCCESS);
        assert_eq!(run.stderr, "");
        assert!(
            run.stdout.ends_with('\n') && !run.stdout.ends_with("\n\n"),
            "{:?}",
            run.stdout
        );
    }
    assert!(help.stdout.contains("arch"), "{}", help.stdout);
    assert!(
        arch_help.stdout.contains("--manifest-path"),
        "{}",
        arch_help.stdout
    );
    assert!(
        arch_help.stdout.contains("--github-actions"),
        "{}",
        arch_help.stdout
    );
    assert!(version.stdout.starts_with("xtask "), "{}", version.stdout);
}

#[test]
fn a_report_that_cannot_be_written_is_never_a_pass() {
    let (model, workspace) = (fixture("valid.toml"), fixture("workspace/Cargo.toml"));
    let args = arch(&model, &workspace);

    assert_eq!(main(args, &mut Broken, &mut Vec::new()), ExitCode::from(2));
}

#[test]
fn a_failure_that_cannot_be_written_exits_with_status_two() {
    let (model, workspace) = (fixture("invalid.toml"), fixture("workspace/Cargo.toml"));
    let args = arch(&model, &workspace);

    assert_eq!(main(args, &mut Vec::new(), &mut Broken), ExitCode::from(2));
}

#[test]
fn a_usage_error_that_cannot_be_written_exits_with_status_two() {
    assert_eq!(
        main(["xtask"], &mut Vec::new(), &mut Broken),
        ExitCode::from(2)
    );
}

#[test]
fn help_that_cannot_be_written_exits_with_status_two() {
    assert_eq!(
        main(["xtask", "--help"], &mut Broken, &mut Vec::new()),
        ExitCode::from(2)
    );
}
