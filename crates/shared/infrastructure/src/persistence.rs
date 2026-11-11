//! PostgreSQL pool factory and the migrations embedded in the binary.

use std::str::FromStr as _;
use std::time::Duration;

use sqlx::PgPool;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};

/// Every migration of the `migrations/` directory at the workspace root, embedded at compile time.
pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("../../../migrations");

/// Settings of the PostgreSQL pool.
///
/// `url` carries the password: never format a value of this type with `{:?}` and never log it.
#[derive(Debug, Clone)]
pub struct PostgresSettings {
    /// `postgres://` or `postgresql://` URL of the database.
    pub url: String,
    /// Upper bound of open connections.
    pub max_connections: u32,
    /// How long a caller waits for a free connection.
    pub acquire_timeout: Duration,
    /// `statement_timeout` set on every connection.
    pub statement_timeout: Duration,
}

/// Builds the pool without opening a connection, so the service starts while the database is down.
///
/// # Errors
///
/// Returns the parse error when `settings.url` is not a valid PostgreSQL URL.
pub fn connect_lazy(settings: &PostgresSettings) -> Result<PgPool, sqlx::Error> {
    let timeout = settings.statement_timeout.as_millis().to_string();
    let options =
        PgConnectOptions::from_str(&settings.url)?.options([("statement_timeout", timeout)]);
    Ok(PgPoolOptions::new()
        .max_connections(settings.max_connections)
        .acquire_timeout(settings.acquire_timeout)
        .connect_lazy_with(options))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn an_unparsable_url_is_rejected_without_network_access() {
        let settings = PostgresSettings {
            url: "not a url".to_owned(),
            max_connections: 1,
            acquire_timeout: Duration::from_millis(100),
            statement_timeout: Duration::from_secs(1),
        };

        let result = connect_lazy(&settings);

        assert!(matches!(result, Err(sqlx::Error::Configuration(_))));
    }

    #[tokio::test]
    async fn a_valid_url_gives_a_pool_that_has_not_connected() {
        let settings = PostgresSettings {
            url: "postgres://app:unused@127.0.0.1:1/app".to_owned(),
            max_connections: 3,
            acquire_timeout: Duration::from_millis(100),
            statement_timeout: Duration::from_secs(1),
        };

        let pool = connect_lazy(&settings).unwrap();

        assert_eq!(pool.size(), 0);
        assert_eq!(pool.options().get_max_connections(), 3);
        assert_eq!(
            pool.options().get_acquire_timeout(),
            Duration::from_millis(100)
        );
    }
}
