//! Spawns the service binary with a cleared environment in a scratch directory outside the repository.

use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU32, Ordering};

/// Every variable of a valid configuration that has no default: the database and the region.
pub(crate) const VALID_ENVIRONMENT: [(&str, &str); 2] = [
    (
        "DATABASE_URL",
        "postgres://app:local-dev-only@127.0.0.1:5432/app",
    ),
    ("AWS_REGION", "us-east-1"),
];

/// URL that nothing listens on: the "unreachable database" case. No container is stopped.
pub(crate) const DEAD_DATABASE_URL: &str = "postgres://app:unused@127.0.0.1:1/app";

static SEQUENCE: AtomicU32 = AtomicU32::new(0);

/// An empty directory under the system temporary directory, removed when the value is dropped.
///
/// It is never below `target/` or the repository: `dotenvy` also searches the parent directories
/// and would find the committed `.env`.
#[derive(Debug)]
pub(crate) struct Scratch {
    path: PathBuf,
}

impl Scratch {
    pub(crate) fn new() -> Self {
        let number = SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("service-it-{}-{number}", std::process::id()));
        fs::create_dir_all(&path).unwrap();
        Self { path }
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    /// Writes a file into the directory.
    pub(crate) fn write(&self, name: &str, contents: &str) {
        fs::write(self.path.join(name), contents).unwrap();
    }

    /// The binary with a cleared environment plus `variables`, and `LLVM_PROFILE_FILE` when the
    /// test process has it, so that coverage of the child is recorded.
    pub(crate) fn service(&self, arguments: &[&str], variables: &[(&str, &str)]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_service"));
        command.args(arguments).env_clear().current_dir(&self.path);
        if let Some(profile) = from_environment("LLVM_PROFILE_FILE") {
            command.env("LLVM_PROFILE_FILE", profile);
        }
        command.envs(variables.iter().copied());
        command
    }

    /// Runs the binary to its end and collects its output.
    pub(crate) fn run(&self, arguments: &[&str], variables: &[(&str, &str)]) -> Output {
        self.service(arguments, variables).output().unwrap()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        // A directory that cannot be removed is left to the operating system's temporary cleanup.
        let _removed = fs::remove_dir_all(&self.path);
    }
}

#[expect(
    clippy::disallowed_methods,
    reason = "the test stack is described by the environment"
)]
fn from_environment(name: &str) -> Option<OsString> {
    std::env::var_os(name)
}

/// Standard output as text.
pub(crate) fn stdout(output: &Output) -> String {
    String::from_utf8(output.stdout.clone()).unwrap()
}

/// Standard error as text.
pub(crate) fn stderr(output: &Output) -> String {
    String::from_utf8(output.stderr.clone()).unwrap()
}

/// The URL of the database a `#[sqlx::test]` gave the test: its name from the server, the rest
/// from `DATABASE_URL`.
pub(crate) async fn database_url(pool: &sqlx::PgPool) -> String {
    let name: String = sqlx::query_scalar("SELECT current_database()")
        .fetch_one(pool)
        .await
        .unwrap();
    let base = from_environment("DATABASE_URL")
        .expect("DATABASE_URL is not set; run the tests through `make`")
        .into_string()
        .unwrap();
    let (server, _database) = base.rsplit_once('/').unwrap();
    format!("{server}/{name}")
}

/// A listener on a free loopback port that accepts connections (the kernel does) and never
/// answers: the peer connects and then waits.
#[expect(
    clippy::disallowed_methods,
    reason = "integration tests open the sockets their subject talks to"
)]
pub(crate) fn silent_listener() -> std::net::TcpListener {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap()
}
