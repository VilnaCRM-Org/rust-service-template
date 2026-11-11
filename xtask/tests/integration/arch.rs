//! The binary against the real workspace (exit 0) and against the fixture workspace (exit 1 and 2).

use std::fs::OpenOptions;
use std::process::Stdio;

use super::support::{fixture, run, workspace_root, xtask};

/// The arguments that check the fixture workspace against `model`.
fn fixture_arguments<'a>(model: &'a str, workspace: &'a str) -> Vec<&'a str> {
    vec!["arch", "--config", model, "--manifest-path", workspace]
}

#[test]
fn the_real_workspace_satisfies_its_architecture_model() {
    let root = workspace_root().display().to_string();
    let (model, manifest) = (
        format!("{root}/architecture.toml"),
        format!("{root}/Cargo.toml"),
    );

    let run = run(&fixture_arguments(&model, &manifest), &[]);

    assert_eq!(run.code, Some(0), "{}{}", run.stdout, run.stderr);
    assert_eq!(
        run.stdout,
        "architecture: ok. All 13 crate(s) are assigned to exactly one layer (7 layer(s)); \
         0 violation(s)\n"
    );
    assert_eq!(run.stderr, "");
}

#[test]
fn the_fixture_workspace_breaks_one_rule_per_planted_violation() {
    let (model, workspace) = (fixture("valid.toml"), fixture("workspace/Cargo.toml"));

    let run = run(&fixture_arguments(&model, &workspace), &[]);

    assert_eq!(run.code, Some(1), "{}", run.stderr);
    assert_eq!(run.stderr, "");
    let stdout = &run.stdout;
    for expected in [
        "error[arch::uncovered]: `stray` is not assigned to any layer\n  --> crates/stray/Cargo.toml\n",
        "error[arch::ambiguous]: `overlap-domain` matches more than one layer: domain, overlap\n  --> crates/overlap/domain/Cargo.toml\n",
        "error[arch::lints]: `nolints-domain` does not inherit the workspace lint policy\n  --> crates/nolints/domain/Cargo.toml\n",
        "error[arch::layer]: `shop-domain` (layer `domain`, context `shop`) must not depend on `shop-infrastructure` (layer `infrastructure`, context `shop`)\n  --> crates/shop/domain/Cargo.toml\n   = help: layer `domain` may depend on: [domain]; ",
    ] {
        assert!(
            stdout.contains(expected),
            "missing {expected:?} in\n{stdout}"
        );
    }
    assert_eq!(stdout.matches("error[arch::").count(), 5, "{stdout}");
    assert!(
        stdout
            .ends_with("architecture: FAILED. 5 violation(s) in 9 crate(s), 5 layer(s) checked\n"),
        "{stdout}"
    );
}

#[test]
fn a_dev_dependency_on_a_dev_layer_is_not_reported_but_the_same_normal_dependency_is() {
    let (model, workspace) = (fixture("valid.toml"), fixture("workspace/Cargo.toml"));

    let run = run(&fixture_arguments(&model, &workspace), &[]);

    assert!(
        !run.stdout.contains("`billing-application`"),
        "{}",
        run.stdout
    );
    assert!(
        run.stdout.contains(
            "error[arch::layer]: `shop-application` (layer `application`, context `shop`) must not depend on `test-support` (layer `test-support`)"
        ),
        "{}",
        run.stdout
    );
}

#[test]
fn github_actions_adds_one_annotation_per_violation() {
    let (model, workspace) = (fixture("valid.toml"), fixture("workspace/Cargo.toml"));
    let arguments = fixture_arguments(&model, &workspace);

    let annotated = run(&arguments, &[("GITHUB_ACTIONS", "true")]);
    let plain = run(&arguments, &[]);
    let disabled = run(&arguments, &[("GITHUB_ACTIONS", "false")]);

    assert_eq!(annotated.code, Some(1));
    let annotations: Vec<&str> = annotated
        .stdout
        .lines()
        .filter(|line| line.starts_with("::error "))
        .collect();
    assert_eq!(annotations.len(), 5, "{}", annotated.stdout);
    assert!(
        annotations.contains(&"::error file=crates/stray/Cargo.toml,title=Architecture (uncovered)::`stray` is not assigned to any layer"),
        "{annotations:?}"
    );
    assert!(!plain.stdout.contains("::error"), "{}", plain.stdout);
    assert!(!disabled.stdout.contains("::error"), "{}", disabled.stdout);
}

#[test]
fn a_model_with_an_unknown_key_could_not_run() {
    let (model, workspace) = (fixture("invalid.toml"), fixture("workspace/Cargo.toml"));

    let run = run(&fixture_arguments(&model, &workspace), &[]);

    assert_eq!(run.code, Some(2));
    assert_eq!(run.stdout, "");
    assert!(
        run.stderr
            .starts_with("architecture check could not run: invalid ")
            && run
                .stderr
                .ends_with("invalid.toml: unknown key `typo` in [[layer]]\n"),
        "{}",
        run.stderr
    );
}

#[test]
fn a_workspace_that_does_not_exist_could_not_run() {
    let (model, workspace) = (
        fixture("valid.toml"),
        fixture("no-such-workspace/Cargo.toml"),
    );

    let run = run(&fixture_arguments(&model, &workspace), &[]);

    assert_eq!(run.code, Some(2));
    assert_eq!(run.stdout, "");
    assert!(
        run.stderr
            .starts_with("architecture check could not run: cannot read the workspace: "),
        "{}",
        run.stderr
    );
}

#[test]
fn a_model_that_does_not_exist_could_not_run() {
    let workspace = fixture("workspace/Cargo.toml");

    let run = run(&fixture_arguments("no-such-model.toml", &workspace), &[]);

    assert_eq!(run.code, Some(2));
    assert!(
        run.stderr
            .starts_with("architecture check could not run: cannot read no-such-model.toml: "),
        "{}",
        run.stderr
    );
}

#[test]
fn a_model_that_covers_nothing_reports_every_crate_as_uncovered() {
    let (model, workspace) = (
        fixture("nothing-covered.toml"),
        fixture("workspace/Cargo.toml"),
    );

    let run = run(&fixture_arguments(&model, &workspace), &[]);

    assert_eq!(run.code, Some(1), "{}", run.stderr);
    assert_eq!(
        run.stdout.matches("error[arch::uncovered]").count(),
        9,
        "{}",
        run.stdout
    );
    assert_eq!(
        run.stdout.matches("error[arch::lints]").count(),
        1,
        "{}",
        run.stdout
    );
    assert!(
        run.stdout
            .contains("`billing-domain` is not assigned to any layer"),
        "{}",
        run.stdout
    );
}

#[test]
fn a_report_that_cannot_be_written_is_never_a_pass() {
    let (model, workspace) = (fixture("valid.toml"), fixture("workspace/Cargo.toml"));
    let full = OpenOptions::new().write(true).open("/dev/full").unwrap();

    let status = xtask(&fixture_arguments(&model, &workspace), &[])
        .stdout(Stdio::from(full))
        .stderr(Stdio::null())
        .status()
        .unwrap();

    assert_eq!(status.code(), Some(2));
}

#[test]
fn a_missing_command_prints_the_usage_and_could_not_run() {
    let run = run(&[], &[]);

    assert_eq!(run.code, Some(2));
    assert_eq!(run.stdout, "");
    assert!(
        run.stderr.contains("Usage: xtask <COMMAND>"),
        "{}",
        run.stderr
    );
}
