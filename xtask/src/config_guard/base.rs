//! The two trees the guard compares: the base ref, read through git, and the working tree.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::Failure;

/// What the checks read. Git is reached only through this trait, so unit tests use an in-memory
/// double.
pub(crate) trait BaseTree {
    /// The bytes of a file at the base ref, or `None` when the base ref has no such file.
    fn base_file(&self, path: &str) -> Result<Option<Vec<u8>>, Failure>;
    /// Every file at the base ref.
    fn base_paths(&self) -> Result<Vec<String>, Failure>;
    /// The bytes of a file of the working tree, or `None` when it is missing or unreadable.
    fn work_file(&self, path: &str) -> Option<Vec<u8>>;
    /// Every file of the working tree that git tracks or would add.
    fn work_paths(&self) -> Result<Vec<String>, Failure>;
    /// Whether the path is a directory of the working tree.
    fn work_dir(&self, path: &str) -> bool;
}

/// The git implementation: a repository root and the commit that the base ref resolved to.
#[derive(Debug)]
pub(crate) struct Git {
    root: PathBuf,
    commit: String,
}

impl Git {
    /// Resolves `base` to a commit. A ref that cannot be resolved (shallow checkout, missing
    /// remote, not a repository) is an error: a guard that cannot compare never passes.
    pub(crate) fn open(root: &Path, base: &str) -> Result<Self, Failure> {
        let spec = format!("{base}^{{commit}}");
        let id = run(
            root,
            &[
                "rev-parse",
                "--verify",
                "--quiet",
                "--end-of-options",
                &spec,
            ],
        )?
        .ok_or_else(|| Failure::BaseUnavailable(base.to_owned()))?;
        Ok(Self {
            root: root.to_owned(),
            commit: String::from_utf8_lossy(&id).trim().to_owned(),
        })
    }
}

impl BaseTree for Git {
    fn base_file(&self, path: &str) -> Result<Option<Vec<u8>>, Failure> {
        let object = format!("{}:./{path}", self.commit);
        run(&self.root, &["cat-file", "blob", &object])
    }

    fn base_paths(&self) -> Result<Vec<String>, Failure> {
        listing(
            &self.root,
            &["ls-tree", "-r", "-z", "--name-only", &self.commit],
        )
    }

    fn work_file(&self, path: &str) -> Option<Vec<u8>> {
        fs::read(self.root.join(path)).ok()
    }

    fn work_paths(&self) -> Result<Vec<String>, Failure> {
        listing(
            &self.root,
            &[
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
            ],
        )
    }

    fn work_dir(&self, path: &str) -> bool {
        self.root.join(path).is_dir()
    }
}

/// Runs git in `root`: its standard output, or `None` when it exits with a failure status.
fn run(root: &Path, arguments: &[&str]) -> Result<Option<Vec<u8>>, Failure> {
    let output = Command::new("git")
        .args(arguments)
        .current_dir(root)
        .output()?;
    Ok(output.status.success().then_some(output.stdout))
}

/// Runs a git command that lists files; a listing that failed is an error, never an empty list.
fn listing(root: &Path, arguments: &[&str]) -> Result<Vec<String>, Failure> {
    let output = run(root, arguments)?.ok_or_else(|| Failure::Listing(arguments.join(" ")))?;
    Ok(names(&output))
}

/// The names of a listing whose entries end with a NUL byte.
fn names(listing: &[u8]) -> Vec<String> {
    listing
        .split(|&byte| byte == 0)
        .filter(|name| !name.is_empty())
        .map(|name| String::from_utf8_lossy(name).into_owned())
        .collect()
}

#[cfg(test)]
mod tests;
