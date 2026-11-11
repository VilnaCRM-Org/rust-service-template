//! The composition root: configuration, command line, wiring of the layer crates, router assembly
//! and the process entry point `run`.

use std::process::ExitCode;

/// Runs the service command line and maps the outcome to a process exit status.
#[must_use]
pub fn run() -> ExitCode {
    ExitCode::from(0)
}
