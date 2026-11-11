//! Unit tests of the parent module.

use super::super::config::{Config, Layer};
use super::super::model::{Crate, Dependency, Workspace};
use super::{Rule, Violation, check};

fn owned(items: &[&str]) -> Vec<String> {
    items.iter().map(|&item| item.to_owned()).collect()
}

fn layer(name: &str, crates: &str, depends_on: &[&str], dev_depends_on: &[&str]) -> Layer {
    Layer {
        name: name.to_owned(),
        crates: owned(&[crates]),
        depends_on: owned(depends_on),
        dev_depends_on: owned(dev_depends_on),
    }
}

fn config() -> Config {
    Config {
        layers: vec![
            layer("domain", "*-domain", &["domain"], &[]),
            layer(
                "application",
                "*-application",
                &["domain", "application"],
                &["test-support"],
            ),
            layer("test-support", "test-support", &["domain"], &[]),
            layer(
                "composition-root",
                "service",
                &["domain", "application"],
                &[],
            ),
        ],
    }
}

/// A dependency as `(name, dev, internal)`.
type Edge = (&'static str, bool, bool);

fn member(name: &str, dependencies: &[Edge]) -> Crate {
    Crate {
        name: name.to_owned(),
        manifest: format!("crates/{name}/Cargo.toml"),
        inherits_lints: true,
        dependencies: dependencies
            .iter()
            .map(|&(name, dev, internal)| Dependency {
                name: name.to_owned(),
                dev,
                internal,
            })
            .collect(),
    }
}

fn check_one(config: &Config, member: Crate) -> Vec<Violation> {
    check(
        config,
        &Workspace {
            crates: vec![member],
        },
    )
}

fn rules(violations: &[Violation]) -> Vec<Rule> {
    violations.iter().map(|violation| violation.rule).collect()
}

#[test]
fn rule_identifiers_are_stable() {
    assert_eq!(Rule::Uncovered.id(), "uncovered");
    assert_eq!(Rule::Ambiguous.id(), "ambiguous");
    assert_eq!(Rule::Layer.id(), "layer");
    assert_eq!(Rule::Lints.id(), "lints");
}

#[test]
fn a_workspace_that_follows_the_rules_is_clean() {
    let workspace = Workspace {
        crates: vec![
            member("shop-domain", &[]),
            member("shop-application", &[("shop-domain", false, true)]),
            member("test-support", &[("shop-domain", false, true)]),
            member(
                "service",
                &[("shop-application", false, true), ("serde", false, false)],
            ),
        ],
    };

    assert_eq!(check(&config(), &workspace), []);
}

#[test]
fn a_layer_may_depend_on_itself() {
    let workspace = Workspace {
        crates: vec![
            member("shop-application", &[]),
            member("billing-application", &[("shop-application", false, true)]),
        ],
    };

    assert_eq!(check(&config(), &workspace), []);
}

#[test]
fn a_crate_that_matches_no_layer_is_uncovered() {
    let violations = check_one(&config(), member("stray", &[]));

    assert_eq!(
        violations,
        [Violation {
            rule: Rule::Uncovered,
            manifest: "crates/stray/Cargo.toml".to_owned(),
            message: "`stray` is not assigned to any layer".to_owned(),
            hint:
                "name the crate `<context>-<layer>` or add its name to the `crates` of a [[layer]]"
                    .to_owned(),
        }]
    );
}

#[test]
fn a_crate_that_matches_two_layers_is_ambiguous() {
    let mut config = config();
    config.layers.push(layer("shop", "shop-*", &[], &[]));

    let violations = check_one(
        &config,
        member("shop-domain", &[("shop-application", false, true)]),
    );

    assert_eq!(
        violations,
        [Violation {
            rule: Rule::Ambiguous,
            manifest: "crates/shop-domain/Cargo.toml".to_owned(),
            message: "`shop-domain` matches more than one layer: domain, shop".to_owned(),
            hint: "make the `crates` patterns of the [[layer]] tables mutually exclusive"
                .to_owned(),
        }]
    );
}

#[test]
fn the_dependencies_of_an_ambiguous_or_uncovered_crate_are_not_judged() {
    let mut config = config();
    config.layers.push(layer("shop", "shop-*", &[], &[]));
    let dependencies = [("service", false, true)];

    assert_eq!(
        rules(&check_one(&config, member("shop-domain", &dependencies))),
        [Rule::Ambiguous]
    );
    assert_eq!(
        rules(&check_one(&config, member("stray", &dependencies))),
        [Rule::Uncovered]
    );
}

#[test]
fn a_crate_without_the_workspace_lints_breaks_the_lints_rule() {
    let mut crate_without_lints = member("shop-domain", &[]);
    crate_without_lints.inherits_lints = false;

    let violations = check_one(&config(), crate_without_lints);

    assert_eq!(
        violations,
        [Violation {
            rule: Rule::Lints,
            manifest: "crates/shop-domain/Cargo.toml".to_owned(),
            message: "`shop-domain` does not inherit the workspace lint policy".to_owned(),
            hint: "add `[lints]` with `workspace = true` to its Cargo.toml".to_owned(),
        }]
    );
}

#[test]
fn the_lints_rule_applies_to_a_crate_outside_every_layer_too() {
    let mut stray = member("stray", &[]);
    stray.inherits_lints = false;

    assert_eq!(
        rules(&check_one(&config(), stray)),
        [Rule::Lints, Rule::Uncovered]
    );
}

#[test]
fn domain_must_not_depend_on_application() {
    let violations = check_one(
        &config(),
        member("shop-domain", &[("shop-application", false, true)]),
    );

    assert_eq!(
        violations,
        [Violation {
            rule: Rule::Layer,
            manifest: "crates/shop-domain/Cargo.toml".to_owned(),
            message: "`shop-domain` (layer `domain`, context `shop`) must not depend on \
                      `shop-application` (layer `application`, context `shop`)"
                .to_owned(),
            hint: "layer `domain` may depend on: [domain]; declare a port (trait) in the inner \
                   layer and implement it in the outer one"
                .to_owned(),
        }]
    );
}

#[test]
fn a_crate_without_a_context_is_named_by_its_layer_alone() {
    let violations = check_one(
        &config(),
        member("test-support", &[("service", false, true)]),
    );

    assert_eq!(
        violations[0].message,
        "`test-support` (layer `test-support`) must not depend on `service` (layer `composition-root`)"
    );
}

#[test]
fn a_dev_dependency_on_a_dev_layer_is_allowed_and_the_same_normal_dependency_is_not() {
    let allowed = check_one(
        &config(),
        member("shop-application", &[("test-support", true, true)]),
    );
    let refused = check_one(
        &config(),
        member("shop-application", &[("test-support", false, true)]),
    );

    assert_eq!(allowed, []);
    assert_eq!(rules(&refused), [Rule::Layer]);
    assert_eq!(
        refused[0].message,
        "`shop-application` (layer `application`, context `shop`) must not depend on `test-support` (layer `test-support`)"
    );
    assert_eq!(
        refused[0].hint,
        "layer `application` may depend on: [domain, application] and, as dev-dependencies, on: \
         [test-support]; declare a port (trait) in the inner layer and implement it in the outer one"
    );
}

#[test]
fn a_dev_dependency_may_use_the_normal_allow_list_too() {
    let violations = check_one(
        &config(),
        member("shop-application", &[("shop-domain", true, true)]),
    );

    assert_eq!(violations, []);
}

#[test]
fn a_dev_dependency_outside_both_lists_is_refused_as_a_dev_dependency() {
    let violations = check_one(
        &config(),
        member("shop-domain", &[("test-support", true, true)]),
    );

    assert_eq!(rules(&violations), [Rule::Layer]);
    assert_eq!(
        violations[0].message,
        "`shop-domain` (layer `domain`, context `shop`) must not have a dev-dependency on `test-support` (layer `test-support`)"
    );
}

#[test]
fn third_party_dependencies_are_not_layer_edges() {
    let violations = check_one(
        &config(),
        member("shop-domain", &[("shop-application", false, false)]),
    );

    assert_eq!(violations, []);
}

#[test]
fn a_dependency_on_a_crate_without_a_layer_is_not_judged_here() {
    let violations = check_one(&config(), member("shop-domain", &[("stray", false, true)]));

    assert_eq!(violations, []);
}

#[test]
fn every_offending_edge_is_reported_in_manifest_order() {
    let violations = check_one(
        &config(),
        member(
            "shop-domain",
            &[
                ("a-application", false, true),
                ("b-domain", false, true),
                ("service", false, true),
            ],
        ),
    );

    assert_eq!(rules(&violations), [Rule::Layer, Rule::Layer]);
    assert!(
        violations[0].message.contains("`a-application`"),
        "{violations:?}"
    );
    assert!(
        violations[1].message.contains("`service`"),
        "{violations:?}"
    );
}

#[test]
fn violations_of_every_crate_are_collected_in_workspace_order() {
    let workspace = Workspace {
        crates: vec![
            member("stray", &[]),
            member("shop-domain", &[("service", false, true)]),
        ],
    };

    let violations = check(&config(), &workspace);

    assert_eq!(rules(&violations), [Rule::Uncovered, Rule::Layer]);
    assert_eq!(violations[0].manifest, "crates/stray/Cargo.toml");
    assert_eq!(violations[1].manifest, "crates/shop-domain/Cargo.toml");
}
