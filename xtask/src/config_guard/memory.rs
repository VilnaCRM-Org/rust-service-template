//! An in-memory `BaseTree` for unit tests: the base ref and the working tree are maps.

use std::collections::{BTreeMap, BTreeSet};

use super::Failure;
use super::base::BaseTree;

/// Files of the base ref, files of the working tree and the directories of the working tree.
#[derive(Debug, Default)]
pub(crate) struct Memory {
    base: BTreeMap<String, Vec<u8>>,
    work: BTreeMap<String, Vec<u8>>,
    directories: BTreeSet<String>,
}

impl Memory {
    /// A file with the same content on the base ref and in the working tree.
    pub(crate) fn same(self, path: &str, text: &str) -> Self {
        self.on_base(path, text).in_work(path, text)
    }

    /// A file of the base ref only (deleted in the working tree).
    pub(crate) fn on_base(mut self, path: &str, text: &str) -> Self {
        self.base.insert(path.to_owned(), text.as_bytes().to_vec());
        self
    }

    /// A file of the working tree only (new, or the changed content of a base file).
    pub(crate) fn in_work(mut self, path: &str, text: &str) -> Self {
        self.work.insert(path.to_owned(), text.as_bytes().to_vec());
        self
    }

    /// A directory of the working tree.
    pub(crate) fn directory(mut self, path: &str) -> Self {
        self.directories.insert(path.to_owned());
        self
    }
}

impl BaseTree for Memory {
    fn base_file(&self, path: &str) -> Result<Option<Vec<u8>>, Failure> {
        Ok(self.base.get(path).cloned())
    }

    fn base_paths(&self) -> Result<Vec<String>, Failure> {
        Ok(self.base.keys().cloned().collect())
    }

    fn work_file(&self, path: &str) -> Option<Vec<u8>> {
        self.work.get(path).cloned()
    }

    fn work_paths(&self) -> Result<Vec<String>, Failure> {
        Ok(self.work.keys().cloned().collect())
    }

    fn work_dir(&self, path: &str) -> bool {
        self.directories.contains(path)
    }
}
