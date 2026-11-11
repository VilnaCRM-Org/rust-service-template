//! Facts about the workspace, independent of where they were read from.

/// Every workspace member.
#[derive(Debug)]
pub(crate) struct Workspace {
    pub(crate) crates: Vec<Crate>,
}

/// One workspace member.
#[derive(Debug)]
pub(crate) struct Crate {
    pub(crate) name: String,
    /// Manifest path relative to the workspace root.
    pub(crate) manifest: String,
    /// Whether the manifest has `[lints] workspace = true`.
    pub(crate) inherits_lints: bool,
    pub(crate) dependencies: Vec<Dependency>,
}

/// A direct dependency declared in the manifest.
#[derive(Debug)]
pub(crate) struct Dependency {
    pub(crate) name: String,
    /// Declared under `[dev-dependencies]`.
    pub(crate) dev: bool,
    /// A workspace member rather than a third-party crate.
    pub(crate) internal: bool,
}
