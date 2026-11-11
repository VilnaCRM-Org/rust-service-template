//! Workspace tooling, run as `cargo xtask <command>`.

use std::process::ExitCode;

/// Entry point; the commands arrive with the stories that own them. Until then the tool reports
/// "could not run" (status 2), the status the gates of this crate use for that case.
fn main() -> ExitCode {
    ExitCode::from(2)
}
