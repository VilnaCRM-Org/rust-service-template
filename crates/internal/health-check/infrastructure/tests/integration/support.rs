//! Settings of the test stack (PostgreSQL and the SQS emulator), read from the environment the Make targets export.

use std::time::Duration;

use shared_infrastructure::messaging::SqsSettings;
use shared_infrastructure::persistence::PostgresSettings;

/// URL that nothing listens on: the "unreachable database" case. No container is stopped.
pub(crate) const DEAD_DATABASE_URL: &str = "postgres://app:unused@127.0.0.1:1/app";

/// Endpoint that nothing listens on: the "unreachable broker" case.
pub(crate) const DEAD_SQS_ENDPOINT: &str = "http://127.0.0.1:1";

#[expect(
    clippy::disallowed_methods,
    reason = "the test stack is described by the environment"
)]
fn env(name: &str) -> String {
    std::env::var(name)
        .unwrap_or_else(|_| panic!("{name} is not set; run the tests through `make`"))
}

/// Settings of the test database `app_test` with generous timeouts.
pub(crate) fn postgres_settings() -> PostgresSettings {
    PostgresSettings {
        url: env("DATABASE_URL"),
        max_connections: 2,
        acquire_timeout: Duration::from_secs(5),
        statement_timeout: Duration::from_secs(5),
    }
}

/// Settings of the SQS emulator of the test stack.
pub(crate) fn sqs_settings() -> SqsSettings {
    SqsSettings {
        region: env("AWS_REGION"),
        endpoint_url: Some(env("AWS_ENDPOINT_URL_SQS")),
        connect_timeout: Duration::from_millis(500),
        operation_timeout: Duration::from_secs(2),
        max_attempts: 1,
    }
}
