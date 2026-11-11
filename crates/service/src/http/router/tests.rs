use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::http::{HeaderMap, Method, Request, StatusCode, header};
use health_check_domain::{Dependency, HealthProbe};
use http_body_util::BodyExt as _;
use serde_json::Value;
use test_support::clock::FixedClock;
use test_support::id::SequenceUuidGenerator;
use test_support::probe::StubProbe;
use test_support::repository::InMemoryExampleApiResourceRepository;

use crate::bootstrap::{Adapters, event_bus, router};
use crate::cli::ServeArgs;
use crate::config::Config;
use crate::graphql::handler::EXPLORER_CONTENT_SECURITY_POLICY;
use crate::http::docs::DOCS_CONTENT_SECURITY_POLICY;
use crate::http::security_headers::DEFAULT_CONTENT_SECURITY_POLICY;
use tower::ServiceExt as _;

const MISSING_ID: &str = "00000000-0000-7000-8000-0000000000ff";

/// Method, path, body, expected status and expected content security policy.
type Route<'a> = (Method, String, Option<&'a str>, StatusCode, &'a str);

struct Answer {
    status: StatusCode,
    headers: HeaderMap,
    body: String,
}

fn config(app_env: &str) -> Config {
    let mut args = ServeArgs {
        app_env: Some(app_env.to_owned()),
        aws_region: Some("us-east-1".to_owned()),
        ..ServeArgs::default()
    };
    args.database.url = Some("postgres://app:unused@127.0.0.1:1/app".to_owned());
    Config::from_args(args).unwrap()
}

fn adapters() -> Adapters {
    let probes: Vec<Arc<dyn HealthProbe>> = vec![
        Arc::new(StubProbe::healthy(Dependency::Database)),
        Arc::new(StubProbe::healthy(Dependency::Cache)),
        Arc::new(StubProbe::healthy(Dependency::MessageBroker)),
    ];
    Adapters {
        repository: Arc::new(InMemoryExampleApiResourceRepository::new()),
        probes,
        event_bus: event_bus(),
        clock: Arc::new(FixedClock::at(std::time::SystemTime::UNIX_EPOCH)),
        uuid_generator: Arc::new(SequenceUuidGenerator::starting_at(1)),
    }
}

async fn send_to(app: &Router, request: Request<Body>) -> Answer {
    let response = app.clone().oneshot(request).await.unwrap();
    let (parts, body) = response.into_parts();
    let bytes = body.collect().await.unwrap().to_bytes();
    Answer {
        status: parts.status,
        headers: parts.headers,
        body: String::from_utf8_lossy(&bytes).into_owned(),
    }
}

async fn send(app_env: &str, request: Request<Body>) -> Answer {
    let app = router(adapters(), &config(app_env)).unwrap();
    send_to(&app, request).await
}

fn request(method: Method, path: &str, body: Option<&str>) -> Request<Body> {
    let builder = Request::builder().method(method).uri(path);
    match body {
        Some(body) => builder
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body.to_owned()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

fn assert_common_headers(answer: &Answer, policy: &str, route: &str) {
    assert!(answer.headers.contains_key("x-request-id"), "{route}");
    assert_eq!(
        answer.headers["x-content-type-options"], "nosniff",
        "{route}"
    );
    assert_eq!(answer.headers["x-frame-options"], "DENY", "{route}");
    assert_eq!(answer.headers["referrer-policy"], "no-referrer", "{route}");
    assert_eq!(answer.headers["content-security-policy"], policy, "{route}");
}

#[tokio::test]
async fn every_route_carries_the_request_id_and_the_security_headers() {
    let graphql = r#"{"query":"{ exampleApiResources { id } }"}"#;
    let create = r#"{"name":"Name","description":"Description"}"#;
    let resource = format!("/api/example_api_resources/{MISSING_ID}");
    let routes: Vec<Route<'_>> = vec![
        (
            Method::POST,
            "/api/example_api_resources".into(),
            Some(create),
            StatusCode::CREATED,
            DEFAULT_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::GET,
            resource,
            None,
            StatusCode::NOT_FOUND,
            DEFAULT_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::GET,
            "/api/example_api_resources".into(),
            None,
            StatusCode::OK,
            DEFAULT_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::POST,
            "/api/graphql".into(),
            Some(graphql),
            StatusCode::OK,
            DEFAULT_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::GET,
            "/api/graphql".into(),
            None,
            StatusCode::OK,
            EXPLORER_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::GET,
            "/api/health".into(),
            None,
            StatusCode::NO_CONTENT,
            DEFAULT_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::GET,
            "/ping".into(),
            None,
            StatusCode::OK,
            DEFAULT_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::GET,
            "/api/docs".into(),
            None,
            StatusCode::OK,
            DOCS_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::GET,
            "/api/docs/openapi.json".into(),
            None,
            StatusCode::OK,
            DEFAULT_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::GET,
            "/api/docs/swagger-ui.css".into(),
            None,
            StatusCode::OK,
            DEFAULT_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::GET,
            "/api/docs/missing.js".into(),
            None,
            StatusCode::NOT_FOUND,
            DEFAULT_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::GET,
            "/api/unknown".into(),
            None,
            StatusCode::NOT_FOUND,
            DEFAULT_CONTENT_SECURITY_POLICY,
        ),
        (
            Method::DELETE,
            "/api/example_api_resources".into(),
            None,
            StatusCode::METHOD_NOT_ALLOWED,
            DEFAULT_CONTENT_SECURITY_POLICY,
        ),
    ];
    let app = router(adapters(), &config("dev")).unwrap();
    for (method, path, body, status, policy) in routes {
        let route = format!("{method} {path}");
        let answer = send_to(&app, request(method, &path, body)).await;
        assert_eq!(answer.status, status, "{route}: {}", answer.body);
        assert_common_headers(&answer, policy, &route);
    }
}

#[tokio::test]
async fn an_unknown_route_is_the_404_problem() {
    let answer = send("test", request(Method::GET, "/api/unknown", None)).await;

    assert_eq!(answer.status, StatusCode::NOT_FOUND);
    assert_eq!(
        answer.headers[header::CONTENT_TYPE],
        "application/problem+json"
    );
    let body: Value = serde_json::from_str(&answer.body).unwrap();
    assert_eq!(body["status"], 404);
    assert_eq!(body["detail"], "No route matches the request path.");
}

#[tokio::test]
async fn a_wrong_method_is_the_405_problem_with_the_allowed_methods() {
    let answer = send(
        "test",
        request(Method::DELETE, "/api/example_api_resources", None),
    )
    .await;

    assert_eq!(answer.status, StatusCode::METHOD_NOT_ALLOWED);
    assert_eq!(
        answer.headers[header::CONTENT_TYPE],
        "application/problem+json"
    );
    let mut allowed: Vec<_> = answer.headers[header::ALLOW]
        .to_str()
        .unwrap()
        .split(',')
        .map(str::trim)
        .collect();
    allowed.sort_unstable();
    assert_eq!(allowed, ["GET", "HEAD", "POST"]);
    let body: Value = serde_json::from_str(&answer.body).unwrap();
    assert_eq!(body["status"], 405);
}

#[tokio::test]
async fn a_panicking_probe_is_the_bare_500_problem() {
    let adapters = adapters().with_probe(Arc::new(StubProbe::panicking(Dependency::Database)));
    let app = router(adapters, &config("test")).unwrap();

    let answer = send_to(&app, request(Method::GET, "/api/health", None)).await;

    assert_eq!(answer.status, StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        answer.headers[header::CONTENT_TYPE],
        "application/problem+json"
    );
    assert_eq!(
        answer.body,
        r#"{"type":"about:blank","title":"Internal Server Error","status":500}"#
    );
    assert_common_headers(&answer, DEFAULT_CONTENT_SECURITY_POLICY, "panic");
}

#[tokio::test]
async fn a_body_over_the_limit_is_the_413_problem() {
    let mut config = config("test");
    config.max_body_bytes = 1024;
    let app = router(adapters(), &config).unwrap();
    let body = format!(r#"{{"name":"{}","description":"d"}}"#, "x".repeat(2048));

    let answer = send_to(
        &app,
        request(Method::POST, "/api/example_api_resources", Some(&body)),
    )
    .await;

    assert_eq!(answer.status, StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(
        answer.headers[header::CONTENT_TYPE],
        "application/problem+json"
    );
    assert_common_headers(&answer, DEFAULT_CONTENT_SECURITY_POLICY, "413");
}

#[tokio::test(start_paused = true)]
async fn a_request_over_its_budget_is_the_503_problem() {
    let mut config = config("test");
    config.request_timeout = Duration::from_secs(1);
    config.health_probe_timeout = Duration::from_secs(60);
    let adapters = adapters().with_probe(Arc::new(StubProbe::hanging(Dependency::Database)));
    let app = router(adapters, &config).unwrap();

    let answer = send_to(&app, request(Method::GET, "/api/health", None)).await;

    assert_eq!(answer.status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        answer.headers[header::CONTENT_TYPE],
        "application/problem+json"
    );
    let body: Value = serde_json::from_str(&answer.body).unwrap();
    assert_eq!(body["detail"], "The request exceeded its time budget.");
    assert_common_headers(&answer, DEFAULT_CONTENT_SECURITY_POLICY, "503");
}

#[tokio::test]
async fn the_explorer_exists_only_in_dev() {
    let dev = send("dev", request(Method::GET, "/api/graphql", None)).await;
    assert_eq!(dev.status, StatusCode::OK);
    assert!(
        dev.headers[header::CONTENT_TYPE]
            .to_str()
            .unwrap()
            .starts_with("text/html")
    );
    assert_eq!(
        dev.headers[header::CONTENT_SECURITY_POLICY],
        EXPLORER_CONTENT_SECURITY_POLICY
    );
    for app_env in ["test", "prod"] {
        let answer = send(app_env, request(Method::GET, "/api/graphql", None)).await;
        assert_eq!(answer.status, StatusCode::METHOD_NOT_ALLOWED, "{app_env}");
        assert_eq!(answer.headers[header::ALLOW], "POST", "{app_env}");
        assert_eq!(
            answer.headers[header::CONTENT_TYPE],
            "application/problem+json",
            "{app_env}"
        );
    }
}

#[tokio::test]
async fn the_other_routes_behave_the_same_in_every_mode() {
    let probes = [
        (Method::GET, "/ping", None),
        (Method::GET, "/api/health", None),
        (Method::GET, "/api/example_api_resources", None),
        (Method::GET, "/api/unknown", None),
        (
            Method::POST,
            "/api/graphql",
            Some(r#"{"query":"{ exampleApiResources { id } }"}"#),
        ),
    ];
    for (method, path, body) in probes {
        let reference = send("dev", request(method.clone(), path, body)).await;
        for app_env in ["test", "prod"] {
            let answer = send(app_env, request(method.clone(), path, body)).await;
            assert_eq!(answer.status, reference.status, "{app_env} {path}");
            assert_eq!(answer.body, reference.body, "{app_env} {path}");
        }
    }
}

#[tokio::test]
async fn a_valid_inbound_request_id_is_kept_and_an_invalid_one_is_replaced() {
    let kept = Request::get("/ping")
        .header("x-request-id", "abc-123")
        .body(Body::empty())
        .unwrap();
    let kept = send("test", kept).await;
    assert_eq!(kept.headers["x-request-id"], "abc-123");

    let invalid = Request::get("/ping")
        .header("x-request-id", "a b")
        .body(Body::empty())
        .unwrap();
    let replaced = send("test", invalid).await;
    assert_ne!(replaced.headers["x-request-id"], "a b");
    assert_eq!(replaced.headers["x-request-id"].len(), 36);
}
