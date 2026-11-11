//! The rules: pure functions from the model and the workspace facts to violations.

use super::config::{Config, Layer};
use super::model::{Crate, Dependency, Workspace};

/// Which rule a violation breaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Rule {
    Uncovered,
    Ambiguous,
    Layer,
    Lints,
}

impl Rule {
    /// Stable identifier printed in reports (`arch::<id>`).
    pub(crate) const fn id(self) -> &'static str {
        match self {
            Self::Uncovered => "uncovered",
            Self::Ambiguous => "ambiguous",
            Self::Layer => "layer",
            Self::Lints => "lints",
        }
    }
}

/// One broken rule, attributed to the crate that must change.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Violation {
    pub(crate) rule: Rule,
    /// Manifest of the offending crate, relative to the workspace root.
    pub(crate) manifest: String,
    pub(crate) message: String,
    pub(crate) hint: String,
}

/// Checks every workspace crate against the configured layers.
pub(crate) fn check(config: &Config, workspace: &Workspace) -> Vec<Violation> {
    workspace
        .crates
        .iter()
        .flat_map(|member| check_crate(config, member))
        .collect()
}

fn check_crate(config: &Config, member: &Crate) -> Vec<Violation> {
    let mut found: Vec<Violation> = check_lints(member).into_iter().collect();
    let layers = config.layers_of(&member.name);
    match layers.as_slice() {
        [layer] => found.extend(check_layer(config, layer, member)),
        [] => found.push(uncovered(member)),
        several => found.push(ambiguous(member, several)),
    }
    found
}

fn check_lints(member: &Crate) -> Option<Violation> {
    (!member.inherits_lints).then(|| {
        violation(
            Rule::Lints,
            member,
            format!(
                "`{}` does not inherit the workspace lint policy",
                member.name
            ),
            "add `[lints]` with `workspace = true` to its Cargo.toml".to_owned(),
        )
    })
}

fn uncovered(member: &Crate) -> Violation {
    violation(
        Rule::Uncovered,
        member,
        format!("`{}` is not assigned to any layer", member.name),
        "name the crate `<context>-<layer>` or add its name to the `crates` of a [[layer]]"
            .to_owned(),
    )
}

fn ambiguous(member: &Crate, layers: &[&Layer]) -> Violation {
    let names: Vec<&str> = layers.iter().map(|layer| layer.name.as_str()).collect();
    violation(
        Rule::Ambiguous,
        member,
        format!(
            "`{}` matches more than one layer: {}",
            member.name,
            names.join(", ")
        ),
        "make the `crates` patterns of the [[layer]] tables mutually exclusive".to_owned(),
    )
}

fn check_layer(config: &Config, layer: &Layer, member: &Crate) -> Vec<Violation> {
    member
        .dependencies
        .iter()
        .filter(|dependency| dependency.internal)
        .filter_map(|dependency| check_edge(config, layer, member, dependency))
        .collect()
}

/// A dependency on a workspace crate must lead to a layer that `depends_on` lists, or, for a
/// dev-dependency, that `dev_depends_on` lists. Targets without exactly one layer are reported by
/// the rules `uncovered` and `ambiguous` and are not judged here.
fn check_edge(
    config: &Config,
    layer: &Layer,
    member: &Crate,
    dependency: &Dependency,
) -> Option<Violation> {
    let targets = config.layers_of(&dependency.name);
    let [target] = targets.as_slice() else {
        return None;
    };
    let allowed = layer.depends_on.contains(&target.name)
        || (dependency.dev && layer.dev_depends_on.contains(&target.name));
    (!allowed).then(|| {
        let kind = if dependency.dev {
            "have a dev-dependency on"
        } else {
            "depend on"
        };
        violation(
            Rule::Layer,
            member,
            format!(
                "{} must not {kind} {}",
                describe(layer, &member.name),
                describe(target, &dependency.name)
            ),
            format!(
                "{}; declare a port (trait) in the inner layer and implement it in the outer one",
                allowance(layer)
            ),
        )
    })
}

/// A crate as the diagnostics name it: `` `a-domain` (layer `domain`, context `a`) ``.
fn describe(layer: &Layer, name: &str) -> String {
    layer.context_of(name).map_or_else(
        || format!("`{name}` (layer `{}`)", layer.name),
        |context| format!("`{name}` (layer `{}`, context `{context}`)", layer.name),
    )
}

fn allowance(layer: &Layer) -> String {
    let normal = format!(
        "layer `{}` may depend on: [{}]",
        layer.name,
        layer.depends_on.join(", ")
    );
    if layer.dev_depends_on.is_empty() {
        normal
    } else {
        format!(
            "{normal} and, as dev-dependencies, on: [{}]",
            layer.dev_depends_on.join(", ")
        )
    }
}

fn violation(rule: Rule, member: &Crate, message: String, hint: String) -> Violation {
    Violation {
        rule,
        manifest: member.manifest.clone(),
        message,
        hint,
    }
}

#[cfg(test)]
mod tests;
