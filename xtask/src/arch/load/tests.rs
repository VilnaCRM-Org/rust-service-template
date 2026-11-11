//! Unit tests of the parent module, against the fixture workspace and the fixture models.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde_json::json;

use super::super::Failure;
use super::super::model::Crate;
use super::{config, inherits_lints, is_internal, workspace};

const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/arch");

fn fixture(path: &str) -> PathBuf {
    Path::new(FIXTURES).join(path)
}

fn members() -> Vec<Crate> {
    workspace(&fixture("workspace/Cargo.toml")).unwrap().crates
}

fn find<'members>(members: &'members [Crate], name: &str) -> &'members Crate {
    members.iter().find(|member| member.name == name).unwrap()
}

fn dependency(name: &str, path: Option<&str>) -> cargo_metadata::Dependency {
    serde_json::from_value(json!({
        "name": name,
        "source": null,
        "req": "*",
        "kind": null,
        "optional": false,
        "uses_default_features": true,
        "features": [],
        "target": null,
        "rename": null,
        "registry": null,
        "path": path,
    }))
    .unwrap()
}

#[test]
fn lists_every_member_sorted_by_name_with_its_manifest_relative_to_the_workspace_root() {
    let found: Vec<(String, String)> = members()
        .into_iter()
        .map(|member| (member.name, member.manifest))
        .collect();

    let expected = [
        ("billing-application", "crates/billing/application"),
        ("billing-domain", "crates/billing/domain"),
        ("nolints-domain", "crates/nolints/domain"),
        ("overlap-domain", "crates/overlap/domain"),
        ("shop-application", "crates/shop/application"),
        ("shop-domain", "crates/shop/domain"),
        ("shop-infrastructure", "crates/shop/infrastructure"),
        ("stray", "crates/stray"),
        ("test-support", "crates/test-support"),
    ];
    let expected: Vec<(String, String)> = expected
        .iter()
        .map(|(name, directory)| ((*name).to_owned(), format!("{directory}/Cargo.toml")))
        .collect();
    assert_eq!(found, expected);
}

#[test]
fn only_an_explicit_workspace_true_counts_as_inheriting_the_lints() {
    let members = members();

    assert!(find(&members, "shop-domain").inherits_lints);
    assert!(!find(&members, "nolints-domain").inherits_lints);
}

#[test]
fn a_manifest_that_cannot_be_read_or_parsed_does_not_inherit_the_lints() {
    assert!(!inherits_lints(&fixture("no-such-manifest.toml")));
    // A file that is not TOML at all.
    assert!(!inherits_lints(&fixture("workspace/crates/stray/lib.txt")));
    // A manifest of a workspace root without a `[lints]` table of its own.
    assert!(!inherits_lints(&fixture("workspace/Cargo.toml")));
}

#[test]
fn direct_dependencies_know_whether_they_are_dev_and_whether_they_are_members() {
    let members = members();
    let facts = |name: &str| -> Vec<(String, bool, bool)> {
        find(&members, name)
            .dependencies
            .iter()
            .map(|dependency| (dependency.name.clone(), dependency.dev, dependency.internal))
            .collect()
    };

    assert_eq!(
        facts("shop-domain"),
        [("shop-infrastructure".to_owned(), false, true)]
    );
    assert_eq!(
        facts("shop-application"),
        [
            ("shop-domain".to_owned(), false, true),
            ("test-support".to_owned(), false, true)
        ]
    );
    assert_eq!(
        facts("billing-application"),
        [
            ("billing-domain".to_owned(), false, true),
            ("test-support".to_owned(), true, true)
        ]
    );
    assert_eq!(facts("stray"), []);
}

#[test]
fn a_dependency_is_internal_when_it_is_a_path_dependency_on_a_member() {
    let members = BTreeSet::from(["member"]);

    assert!(is_internal(
        &dependency("member", Some("/work/member")),
        &members
    ));
    assert!(!is_internal(&dependency("member", None), &members));
    assert!(!is_internal(
        &dependency("vendored", Some("/work/vendored")),
        &members
    ));
    assert!(!is_internal(&dependency("serde", None), &members));
}

#[test]
fn a_missing_manifest_could_not_be_read() {
    let error = workspace(&fixture("no-such-workspace/Cargo.toml")).unwrap_err();

    assert!(matches!(error, Failure::Metadata(_)), "{error}");
    assert!(
        error.to_string().starts_with("cannot read the workspace: "),
        "{error}"
    );
}

#[test]
fn reads_the_layer_model() {
    let model = config(&fixture("valid.toml")).unwrap();

    let layers: Vec<(&str, &[String])> = model
        .layers
        .iter()
        .map(|layer| (layer.name.as_str(), layer.depends_on.as_slice()))
        .collect();
    assert_eq!(layers.len(), 5);
    assert_eq!(layers[0].0, "domain");
    assert_eq!(layers[1].0, "application");
    assert_eq!(layers[1].1, ["domain", "application"]);
    assert_eq!(model.layers[1].dev_depends_on, ["test-support"]);
}

#[test]
fn a_model_without_layers_is_valid() {
    assert!(
        config(&fixture("nothing-covered.toml"))
            .unwrap()
            .layers
            .is_empty()
    );
}

#[test]
fn a_missing_model_could_not_be_read() {
    let error = config(&fixture("no-such-model.toml")).unwrap_err();

    assert!(matches!(error, Failure::Read { .. }), "{error}");
    assert!(error.to_string().starts_with("cannot read "), "{error}");
    assert!(
        error.to_string().contains("no-such-model.toml: "),
        "{error}"
    );
}

#[test]
fn a_model_that_is_not_toml_is_invalid() {
    let error = config(&fixture("workspace/crates/stray/lib.txt")).unwrap_err();

    assert!(matches!(error, Failure::Config { .. }), "{error}");
    assert!(error.to_string().starts_with("invalid "), "{error}");
    assert!(error.to_string().contains("lib.txt: "), "{error}");
}

#[test]
fn a_model_with_an_unknown_key_is_invalid_and_names_the_key() {
    let error = config(&fixture("invalid.toml")).unwrap_err();

    assert!(matches!(error, Failure::UnknownKey { .. }), "{error}");
    assert!(
        error
            .to_string()
            .ends_with("invalid.toml: unknown key `typo` in [[layer]]"),
        "{error}"
    );
}
