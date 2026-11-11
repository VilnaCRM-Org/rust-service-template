//! Reads `architecture.toml` and turns `cargo metadata` into the workspace model.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use cargo_metadata::{DependencyKind, Metadata, MetadataCommand, Package};
use toml::Table;

use super::Failure;
use super::config::{self, Config};
use super::model::{Crate, Dependency, Workspace};

/// Reads and validates the configuration file.
pub(crate) fn config(path: &Path) -> Result<Config, Failure> {
    let text = fs::read_to_string(path).map_err(|source| Failure::Read {
        path: path.to_owned(),
        source,
    })?;
    let invalid = |source| Failure::Config {
        path: path.to_owned(),
        source,
    };
    let table = text.parse::<Table>().map_err(invalid)?;
    config::check_keys(&table).map_err(|unknown| Failure::UnknownKey {
        path: path.to_owned(),
        table: unknown.table,
        key: unknown.key,
    })?;
    table.try_into().map_err(invalid)
}

/// Runs `cargo metadata --locked` and extracts the facts the rules need.
pub(crate) fn workspace(manifest: &Path) -> Result<Workspace, Failure> {
    let metadata = MetadataCommand::new()
        .manifest_path(manifest)
        .other_options(vec!["--locked".to_owned()])
        .exec()?;
    let members: BTreeSet<&str> = metadata
        .workspace_packages()
        .into_iter()
        .map(|package| package.name.as_str())
        .collect();
    let mut crates: Vec<Crate> = metadata
        .workspace_packages()
        .into_iter()
        .map(|package| member(&metadata, &members, package))
        .collect();
    crates.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(Workspace { crates })
}

fn member(metadata: &Metadata, members: &BTreeSet<&str>, package: &Package) -> Crate {
    let relative = package
        .manifest_path
        .strip_prefix(&metadata.workspace_root)
        .unwrap_or(&package.manifest_path);
    Crate {
        name: package.name.to_string(),
        manifest: relative.to_string(),
        inherits_lints: inherits_lints(package.manifest_path.as_std_path()),
        dependencies: package
            .dependencies
            .iter()
            .map(|dependency| Dependency {
                name: dependency.name.clone(),
                dev: dependency.kind == DependencyKind::Development,
                internal: is_internal(dependency, members),
            })
            .collect(),
    }
}

/// Whether a dependency is a workspace member: a path dependency whose package is a member.
fn is_internal(dependency: &cargo_metadata::Dependency, members: &BTreeSet<&str>) -> bool {
    dependency.path.is_some() && members.contains(dependency.name.as_str())
}

/// Whether the manifest has `[lints] workspace = true`. Cargo has already parsed the file, so
/// "unreadable" can only mean "no".
fn inherits_lints(manifest: &Path) -> bool {
    let table = fs::read_to_string(manifest)
        .ok()
        .and_then(|text| text.parse::<Table>().ok());
    let inherited = table
        .as_ref()
        .and_then(|table| table.get("lints")?.get("workspace")?.as_bool());
    inherited == Some(true)
}

#[cfg(test)]
mod tests;
