//! Command line: parses the arguments, runs the command and maps its outcome to an exit status.
//!
//! Exit statuses: 0 the command found nothing to report, 1 it reported violations, 2 it could not
//! run (usage error, unreadable input, failed output). This is the only module that writes output,
//! and the only one that reads the process environment (through clap).

use std::ffi::OsString;
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

use crate::arch;

/// Exit status of a command that could not run, as opposed to one that found violations.
const COULD_NOT_RUN: u8 = 2;

/// Workspace tooling, run as `cargo xtask <command>`.
#[derive(Debug, Parser)]
#[command(name = "xtask", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Check the workspace against the layer model of architecture.toml
    Arch(ArchArgs),
}

#[derive(Debug, Args)]
struct ArchArgs {
    /// The layer model
    #[arg(long, value_name = "FILE", default_value = "architecture.toml")]
    config: PathBuf,
    /// The manifest of the workspace to check
    #[arg(long, value_name = "FILE", default_value = "Cargo.toml")]
    manifest_path: PathBuf,
    /// Also print one GitHub annotation per violation (set by GitHub Actions)
    #[arg(long = "github-actions", env = "GITHUB_ACTIONS")]
    github: bool,
}

/// Runs the command named by `args` (the program name first) and returns its exit status.
pub(crate) fn main<I, T>(args: I, stdout: &mut dyn Write, stderr: &mut dyn Write) -> ExitCode
where
    I: IntoIterator<Item = T>,
    T: Into<OsString> + Clone,
{
    match Cli::try_parse_from(args) {
        Ok(cli) => execute(cli.command, stdout, stderr),
        Err(error) => usage(&error, stdout, stderr),
    }
}

/// Prints a usage error to stderr (status 2) or the help text to stdout (status 0).
fn usage(error: &clap::Error, stdout: &mut dyn Write, stderr: &mut dyn Write) -> ExitCode {
    let text = error.render().to_string();
    if error.use_stderr() {
        finish(
            writeln!(stderr, "{}", text.trim_end()),
            ExitCode::from(COULD_NOT_RUN),
        )
    } else {
        finish(writeln!(stdout, "{}", text.trim_end()), ExitCode::SUCCESS)
    }
}

fn execute(command: Command, stdout: &mut dyn Write, stderr: &mut dyn Write) -> ExitCode {
    match command {
        Command::Arch(args) => architecture(args, stdout, stderr),
    }
}

fn architecture(args: ArchArgs, stdout: &mut dyn Write, stderr: &mut dyn Write) -> ExitCode {
    let options = arch::Options {
        config: args.config,
        manifest: args.manifest_path,
        github: args.github,
    };
    match arch::run(&options) {
        Ok(outcome) => {
            let code = if outcome.clean {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            };
            finish(writeln!(stdout, "{}", outcome.report), code)
        }
        Err(failure) => {
            let reason = failure.to_string();
            finish(
                writeln!(
                    stderr,
                    "architecture check could not run: {}",
                    reason.trim_end()
                ),
                ExitCode::from(COULD_NOT_RUN),
            )
        }
    }
}

/// A command whose output cannot be written has not reported anything: it never passes.
fn finish(written: io::Result<()>, code: ExitCode) -> ExitCode {
    written.map_or_else(|_error| ExitCode::from(COULD_NOT_RUN), |()| code)
}

#[cfg(test)]
mod tests;
