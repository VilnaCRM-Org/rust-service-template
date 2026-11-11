//! Runs the built `xtask` binary the way the tests need it: with a cleared environment, a working
//! directory outside the repository and the few variables that `cargo` and the coverage tool need.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Variables copied from the test process when it has them: the coverage profile of the child,
/// and what `cargo metadata` needs to be found and to run. Nothing else is forwarded; a test sets
/// any other variable (`GITHUB_ACTIONS`, ...) explicitly.
const FORWARDED: [&str; 6] = [
    "LLVM_PROFILE_FILE",
    "PATH",
    "HOME",
    "CARGO_HOME",
    "RUSTUP_HOME",
    "RUSTUP_TOOLCHAIN",
];

/// The result of one run of the binary.
#[derive(Debug)]
pub(crate) struct Run {
    pub(crate) code: Option<i32>,
    pub(crate) stdout: String,
    pub(crate) stderr: String,
}

/// The command that runs the binary with `arguments` and the variables the test sets.
pub(crate) fn xtask(arguments: &[&str], variables: &[(&str, &str)]) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_xtask"));
    command
        .args(arguments)
        .env_clear()
        .current_dir(empty_directory());
    for name in FORWARDED {
        if let Some(value) = from_environment(name) {
            command.env(name, value);
        }
    }
    command.envs(variables.iter().copied());
    command
}

/// Runs the binary and waits for its exit status.
pub(crate) fn run(arguments: &[&str], variables: &[(&str, &str)]) -> Run {
    let output = xtask(arguments, variables).output().unwrap();
    Run {
        code: output.status.code(),
        stdout: String::from_utf8(output.stdout).unwrap(),
        stderr: String::from_utf8(output.stderr).unwrap(),
    }
}

/// A file or directory below `tests/fixtures/arch/`, as a string for the command line.
pub(crate) fn fixture(path: &str) -> String {
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/arch");
    fixtures.join(path).display().to_string()
}

/// The root of the real workspace, which is the parent of the `xtask` package.
pub(crate) fn workspace_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_owned()
}

#[expect(
    clippy::disallowed_methods,
    reason = "the test stack is described by the environment"
)]
fn from_environment(name: &str) -> Option<OsString> {
    std::env::var_os(name)
}

/// A directory under the system temporary directory: never below `target/` and never inside the
/// repository, where a configuration file of the repository could be found from the child.
fn empty_directory() -> PathBuf {
    let directory = std::env::temp_dir().join(format!("xtask-it-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    directory
}
