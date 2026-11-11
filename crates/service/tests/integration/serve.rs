//! `service serve` as a process: start-up, the request log, shutdown, failures and outages.

use std::io::{Read as _, Write as _};
use std::time::Duration;

use serde_json::Value;
use sqlx::PgPool;
use tokio::time::Instant;

use crate::support::{
    DEAD_DATABASE_URL, Scratch, Server, VALID_ENVIRONMENT, database_url, serve, stack_with,
};

const REQUEST_ID: &str = "serve-test-1";

/// The configuration of a service that starts but whose dependencies do not answer.
const DEAD_DEPENDENCIES: [(&str, &str); 3] = [
    ("DATABASE_URL", DEAD_DATABASE_URL),
    ("AWS_REGION", "us-east-1"),
    ("AWS_ENDPOINT_URL_SQS", "http://127.0.0.1:1"),
];

/// Messages written outside a request.
const OUTSIDE_REQUESTS: [&str; 3] = ["listening", "shutdown signal received", "stopped"];

fn dead_server(scratch: &Scratch, extra: &[(&str, &str)]) -> Server {
    let mut variables = DEAD_DEPENDENCIES.to_vec();
    variables.extend_from_slice(extra);
    serve(scratch, &variables)
}

fn as_pairs<'a>(owned: &'a [(&'static str, String)]) -> Vec<(&'static str, &'a str)> {
    owned
        .iter()
        .map(|(name, value)| (*name, value.as_str()))
        .collect()
}

fn messages_of<'a>(lines: &'a [Value], message: &str) -> Vec<&'a Value> {
    lines
        .iter()
        .filter(|line| line["message"] == message)
        .collect()
}

#[sqlx::test(migrator = "shared_infrastructure::persistence::MIGRATOR")]
async fn a_request_sequence_is_logged_as_json_with_the_request_id(pool: PgPool) {
    let scratch = Scratch::new();
    let url = database_url(&pool).await;
    let owned = stack_with(&url);
    let server = serve(&scratch, &as_pairs(&owned));
    let headers = [
        ("x-request-id", REQUEST_ID),
        ("content-type", "application/json"),
    ];
    let body = r#"{"name":"Serve test","description":"Created through the spawned binary"}"#;

    let ping = server.request("GET", "/ping", &headers, "");
    let health = server.request("GET", "/api/health", &headers, "");
    let created = server.request("POST", "/api/example_api_resources", &headers, body);
    let unknown = server.request("GET", "/no-such-route", &headers, "");
    let finished = server.terminate();

    assert_eq!((ping.status, ping.body.as_str()), (200, "pong"));
    assert_eq!(health.status, 204);
    assert!(
        ping.head.contains("x-request-id: serve-test-1"),
        "{}",
        ping.head
    );
    assert_eq!(created.status, 201, "{}", created.body);
    assert_eq!(unknown.status, 404);
    assert_eq!(finished.code, Some(0));
    assert_eq!(finished.stderr, "");
    let listening = &finished.lines[0];
    assert_eq!(listening["message"], "listening");
    assert_eq!(listening["level"], "INFO");
    assert!(
        listening["addr"]
            .as_str()
            .unwrap()
            .starts_with("127.0.0.1:")
    );
    assert_eq!(listening["env"], "prod");
    assert_eq!(listening["version"], env!("CARGO_PKG_VERSION"));
    for line in &finished.lines {
        for key in ["timestamp", "level", "message"] {
            assert!(line[key].is_string(), "{key} missing in {line}");
        }
    }
    let inside: Vec<&Value> = finished
        .lines
        .iter()
        .filter(|line| !OUTSIDE_REQUESTS.contains(&line["message"].as_str().unwrap()))
        .collect();
    assert!(
        inside
            .iter()
            .all(|line| line["span"]["request_id"] == REQUEST_ID),
        "{inside:?}"
    );
    assert_eq!(messages_of(&finished.lines, "request completed").len(), 4);
    assert_eq!(messages_of(&finished.lines, "domain event").len(), 1);
}

#[test]
fn the_start_up_entry_names_the_mode() {
    for mode in ["dev", "test", "prod"] {
        let scratch = Scratch::new();
        let server = dead_server(&scratch, &[("APP_ENV", mode)]);

        let finished = server.terminate();

        assert_eq!(finished.lines[0]["env"], mode);
        assert_eq!(finished.code, Some(0));
    }
}

#[test]
fn an_idle_service_stops_on_sigterm_within_two_seconds() {
    let scratch = Scratch::new();
    let server = dead_server(&scratch, &[]);
    let started = Instant::now();

    let finished = server.terminate();

    assert_eq!(finished.code, Some(0));
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "{:?}",
        started.elapsed()
    );
    assert_eq!(
        finished.messages(),
        ["listening", "shutdown signal received", "stopped"]
    );
    assert_eq!(finished.lines[1]["signal"], "SIGTERM");
    assert_eq!(finished.lines[1]["level"], "INFO");
    assert_eq!(finished.lines[2]["level"], "INFO");
    assert_eq!(finished.stderr, "");
}

#[test]
fn sigint_stops_the_service_like_sigterm() {
    let scratch = Scratch::new();
    let server = dead_server(&scratch, &[]);

    server.signal("INT");
    let finished = server.finish();

    assert_eq!(finished.code, Some(0));
    assert_eq!(finished.lines[1]["signal"], "SIGINT");
    assert_eq!(finished.lines[2]["message"], "stopped");
    assert_eq!(finished.lines[1]["level"], "INFO");
    assert_eq!(finished.lines[2]["level"], "INFO");
}

#[test]
fn a_request_in_flight_completes_and_new_connections_are_refused() {
    let scratch = Scratch::new();
    let mut server = dead_server(&scratch, &[]);
    let mut stream = server.begin("/ping");
    std::thread::sleep(Duration::from_millis(200));

    server.signal("TERM");
    server.read_until("shutdown signal received");
    server.wait_until_refusing(Duration::from_secs(2));
    stream.write_all(b"\r\n").unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    let finished = server.finish();

    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    assert!(response.ends_with("pong"), "{response}");
    assert_eq!(finished.code, Some(0));
    assert_eq!(finished.lines.last().unwrap()["message"], "stopped");
}

#[test]
fn a_connection_open_at_the_end_of_the_grace_period_forces_exit_status_1() {
    let scratch = Scratch::new();
    let mut server = dead_server(&scratch, &[("SHUTDOWN_GRACE_PERIOD", "1s")]);
    let mut stream = server.begin("/ping");
    std::thread::sleep(Duration::from_millis(200));
    let started = Instant::now();

    server.signal("TERM");
    server.read_until("shutdown signal received");
    let finished = server.finish();
    let elapsed = started.elapsed();
    let mut rest = String::new();
    let read = stream.read_to_string(&mut rest);

    assert_eq!(finished.code, Some(1));
    assert!(elapsed >= Duration::from_secs(1), "{elapsed:?}");
    assert!(elapsed < Duration::from_secs(3), "{elapsed:?}");
    let last = finished.lines.last().unwrap();
    assert_eq!(last["message"], "grace period elapsed, forcing shutdown");
    assert_eq!(last["level"], "WARN");
    assert_eq!(last["grace_period"], "1s");
    assert!(!finished.messages().contains(&"stopped"));
    assert!(
        read.is_err() || rest.is_empty(),
        "the connection was answered: {rest}"
    );
    assert_eq!(finished.stderr, "");
}

#[test]
fn a_port_in_use_is_one_serve_failed_entry_and_exit_status_1() {
    let scratch = Scratch::new();
    let first = dead_server(&scratch, &[]);
    let port = first.port.to_string();
    let mut variables = DEAD_DEPENDENCIES.to_vec();
    variables.extend([("APP_PORT", port.as_str()), ("APP_HOST", "127.0.0.1")]);

    let second = scratch.run(&["serve"], &variables);
    let first = first.terminate();

    assert_eq!(second.status.code(), Some(1));
    assert_eq!(crate::support::stderr(&second), "");
    let stdout = crate::support::stdout(&second);
    let lines: Vec<Value> = stdout
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(lines.len(), 1, "{stdout}");
    assert_eq!(lines[0]["message"], "serve failed");
    assert_eq!(lines[0]["level"], "ERROR");
    assert!(
        lines[0]["error"]
            .as_str()
            .is_some_and(|error| !error.is_empty())
    );
    assert_eq!(first.code, Some(0));
}

#[test]
fn an_invalid_variable_is_one_json_entry_per_problem_and_exit_status_2() {
    let scratch = Scratch::new();
    let variables = [
        ("APP_PORT", "eighty"),
        ("DATABASE_URL", "mysql://root:hunter2@db/app"),
    ];

    let output = scratch.run(&["serve"], &variables);

    assert_eq!(output.status.code(), Some(2));
    assert_eq!(crate::support::stderr(&output), "");
    let stdout = crate::support::stdout(&output);
    let lines: Vec<Value> = stdout
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let named: Vec<&str> = lines
        .iter()
        .map(|line| line["variable"].as_str().unwrap())
        .collect();
    assert_eq!(named, ["APP_PORT", "DATABASE_URL", "AWS_REGION"]);
    for line in &lines {
        assert_eq!(line["message"], "invalid configuration");
        assert_eq!(line["level"], "ERROR");
        assert!(
            line["reason"]
                .as_str()
                .is_some_and(|reason| !reason.is_empty())
        );
    }
    assert!(!stdout.contains("hunter2"));
}

#[test]
fn unreachable_dependencies_do_not_stop_ping_and_health_names_them() {
    let scratch = Scratch::new();
    let started = Instant::now();
    let server = dead_server(&scratch, &[]);

    let ping = server.get("/ping");
    let ping_after = started.elapsed();
    let probed = Instant::now();
    let health = server.get("/api/health");
    let probe_took = probed.elapsed();
    let finished = server.terminate();

    assert_eq!(ping.status, 200);
    assert!(ping_after < Duration::from_secs(5), "{ping_after:?}");
    assert_eq!(health.status, 500);
    assert!(probe_took < Duration::from_secs(4), "{probe_took:?}");
    assert!(health.body.contains("Database"), "{}", health.body);
    assert!(health.body.contains("Message broker"), "{}", health.body);
    assert!(!health.body.contains("Cache"), "{}", health.body);
    assert_eq!(finished.code, Some(0));
}

#[test]
fn the_database_url_and_credentials_are_never_logged() {
    let scratch = Scratch::new();
    let mut variables = VALID_ENVIRONMENT.to_vec();
    variables.push(("AWS_ENDPOINT_URL_SQS", "http://127.0.0.1:1"));
    variables[0] = ("DATABASE_URL", "postgres://app:s3cret-pass@127.0.0.1:1/app");
    let server = serve(&scratch, &variables);
    let _answer = server.get("/api/health");

    let finished = server.terminate();

    let text = serde_json::to_string(&finished.lines).unwrap();
    assert!(!text.contains("s3cret-pass"), "{text}");
}
