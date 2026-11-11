//! Bounded-context scaffolding: creates the three layer crates of a new context and registers them in
//! the workspace.
//!
//! The crates have no dependency, so they pass the architecture gate, the crate-isolation gate and
//! the unused-dependency gate as they are. After the files are written the lock file is refreshed
//! offline (`lock.rs`), because three new members make `cargo metadata --locked` fail otherwise.

mod lock;
mod name;
mod template;
mod workspace;

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use thiserror::Error;

use self::template::Layer;

/// The directory below the workspace root that holds every context.
const CRATES: &str = "crates";

/// The manifest of the workspace, relative to its root.
const MANIFEST: &str = "Cargo.toml";

/// A request that was understood and turned down; nothing was changed.
#[derive(Debug, Error, PartialEq, Eq)]
pub(crate) enum Refusal {
    #[error(
        "the {kind} name `{name}` is invalid: use lowercase letters and digits in words that are \
         separated by single hyphens, and start with a letter"
    )]
    InvalidName { kind: &'static str, name: String },
    #[error("`{0}` is reserved and cannot name a bounded context")]
    Reserved(String),
    #[error("the bounded context `{context}` already exists at {path}")]
    Exists { context: String, path: String },
}

/// Why the command could not do its work.
#[derive(Debug, Error)]
pub(crate) enum Fault {
    #[error("cannot read {path}: {source}")]
    Read { path: String, source: io::Error },
    #[error("cannot parse {MANIFEST}: {0}")]
    Parse(#[from] toml_edit::TomlError),
    #[error("{MANIFEST} has no [workspace].members array")]
    NoMembers,
    #[error("cannot write {path}: {source}")]
    Write { path: String, source: io::Error },
    #[error("cannot run `cargo update --workspace --offline`: {0}")]
    RunCargo(io::Error),
    #[error(
        "the crates were created, but `cargo update --workspace --offline` failed, so Cargo.lock is \
         stale: {0}"
    )]
    Lock(String),
}

/// Why a run did not create a context: it was refused (exit status 1) or could not run (status 2).
#[derive(Debug, Error)]
pub(crate) enum Failure {
    #[error("{0}")]
    Refused(#[from] Refusal),
    #[error("{0}")]
    CouldNotRun(#[from] Fault),
}

/// Creates the context in the workspace at `root` and returns the text to print: what was created
/// and the steps that remain.
pub(crate) fn run(root: &Path, group: &str, context: &str) -> Result<String, Failure> {
    let members = create(root, group, context)?;
    lock::refresh(root)?;
    Ok(report(context, &members))
}

/// Validates the names, then writes the crates and registers them in the root manifest. A refusal
/// and an unreadable manifest are reported before anything is written. Returns the member paths.
fn create(root: &Path, group: &str, context: &str) -> Result<Vec<String>, Failure> {
    name::check(group, context)?;
    let members: Vec<String> = Layer::ALL
        .iter()
        .map(|layer| format!("{CRATES}/{group}/{context}/{}", layer.directory()))
        .collect();
    let manifest = root.join(MANIFEST);
    let text = fs::read_to_string(&manifest).map_err(|source| Fault::Read {
        path: MANIFEST.to_owned(),
        source,
    })?;
    let registered = workspace::add_members(&text, &members)?;
    if let Some(existing) = existing(root, context) {
        return Err(Refusal::Exists {
            context: context.to_owned(),
            path: relative(root, &existing),
        }
        .into());
    }
    for (layer, member) in Layer::ALL.iter().zip(&members) {
        let directory = root.join(member);
        let rendered = template::render(*layer, context);
        write(&directory.join(MANIFEST), &rendered.manifest)?;
        write(&directory.join("src/lib.rs"), &rendered.lib)?;
    }
    write(&manifest, &registered)?;
    Ok(members)
}

/// The directory of a context of this name in any group, if there is one: a context directory name
/// is unique in the workspace, whatever its group. A missing or unreadable `crates` has none.
fn existing(root: &Path, context: &str) -> Option<PathBuf> {
    fs::read_dir(root.join(CRATES))
        .into_iter()
        .flatten()
        .flatten()
        .map(|group| group.path().join(context))
        .find(|candidate| candidate.is_dir())
}

fn relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .display()
        .to_string()
}

/// Writes a file and the directories above it.
fn write(path: &Path, contents: &str) -> Result<(), Fault> {
    let written = path
        .parent()
        .map_or(Ok(()), fs::create_dir_all)
        .and_then(|()| fs::write(path, contents));
    written.map_err(|source| Fault::Write {
        path: path.display().to_string(),
        source,
    })
}

/// The steps that no command can take for the developer.
const NEXT_STEPS: [&str; 6] = [
    "Next steps:",
    "  1. Add [workspace.dependencies] path entries for the new crates when the first crate depends on them.",
    "  2. Add the code layer by layer and put the fakes of its ports in test-support.",
    "  3. Wire the context in the composition root (`service`): adapters in `Adapters`, handlers in `bootstrap::router`,",
    "     a state field in `AppState`, its router in `openapi::api_router` and its GraphQL roots in `graphql::schema`.",
    "  4. Add its three components to workspace.dsl; until then the architecture model check fails.",
];

/// What was created and what the developer does next.
fn report(context: &str, members: &[String]) -> String {
    let mut lines = vec![format!("Created the bounded context `{context}`:")];
    lines.extend(members.iter().map(|member| format!("  {member}")));
    lines.push(
        "Registered the three crates in [workspace].members and refreshed Cargo.lock.".to_owned(),
    );
    lines.push(String::new());
    lines.extend(NEXT_STEPS.map(str::to_owned));
    lines.join("\n")
}

#[cfg(test)]
mod tests;
