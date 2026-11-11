//! `service healthcheck` against a running service and against a port nothing listens on.

use crate::support::{DEAD_DATABASE_URL, Scratch, serve, silent_listener};

fn exit_code(scratch: &Scratch, arguments: &[&str], port: &str) -> Option<i32> {
    scratch.run(arguments, &[("APP_PORT", port)]).status.code()
}

#[test]
fn succeeds_against_a_running_service_and_fails_with_nothing_listening() {
    let scratch = Scratch::new();
    let server = serve(
        &scratch,
        &[
            ("DATABASE_URL", DEAD_DATABASE_URL),
            ("AWS_REGION", "us-east-1"),
        ],
    );
    let port = server.port.to_string();
    let alive = exit_code(&scratch, &["healthcheck"], &port);
    let flag = scratch
        .run(&["healthcheck", "--port", &port], &[])
        .status
        .code();
    let finished = server.terminate();
    let dead = exit_code(&scratch, &["healthcheck"], &port);

    assert_eq!(alive, Some(0));
    assert_eq!(flag, Some(0));
    assert_eq!(finished.code, Some(0));
    assert_eq!(dead, Some(1));
}

#[test]
fn an_unparsable_port_and_a_listener_that_never_answers_fail() {
    let scratch = Scratch::new();
    let listener = silent_listener();
    let port = listener.local_addr().unwrap().port().to_string();
    let started = tokio::time::Instant::now();

    let unparsable = exit_code(&scratch, &["healthcheck"], "not-a-port");
    let silent = exit_code(&scratch, &["healthcheck"], &port);

    assert_eq!(unparsable, Some(1));
    assert_eq!(silent, Some(1));
    assert!(
        started.elapsed() >= std::time::Duration::from_secs(2),
        "{:?}",
        started.elapsed()
    );
    assert!(
        started.elapsed() < std::time::Duration::from_secs(4),
        "{:?}",
        started.elapsed()
    );
}

#[test]
fn prints_nothing() {
    let scratch = Scratch::new();

    let output = scratch.run(&["healthcheck"], &[("APP_PORT", "1")]);

    assert_eq!(output.status.code(), Some(1));
    assert_eq!(output.stdout, Vec::<u8>::new());
    assert_eq!(output.stderr, Vec::<u8>::new());
}
