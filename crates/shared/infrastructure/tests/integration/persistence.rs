use std::time::Duration;

use shared_infrastructure::persistence::{MIGRATOR, PostgresSettings, connect_lazy};
use sqlx::{PgPool, Row as _};
use tokio::time::Instant;

use crate::support;

const COLUMNS: &str = "SELECT table_name::text, column_name::text, data_type::text, is_nullable::text, \
    ordinal_position::text FROM information_schema.columns \
    WHERE table_schema = current_schema() AND table_name <> '_sqlx_migrations' \
    ORDER BY table_name, ordinal_position";

const CONSTRAINTS: &str = "SELECT conrelid::regclass::text, conname::text, contype::text, \
    pg_get_constraintdef(oid) FROM pg_constraint \
    WHERE connamespace = current_schema()::regnamespace AND conrelid <> '_sqlx_migrations'::regclass \
    ORDER BY conname";

type Catalog = (Vec<Vec<String>>, Vec<Vec<String>>);

async fn rows(pool: &PgPool, sql: &'static str) -> Vec<Vec<String>> {
    let rows = sqlx::query(sql).fetch_all(pool).await.unwrap();
    rows.iter()
        .map(|row| {
            (0..row.len())
                .map(|index| row.get::<String, _>(index))
                .collect()
        })
        .collect()
}

async fn catalog(pool: &PgPool) -> Catalog {
    (rows(pool, COLUMNS).await, rows(pool, CONSTRAINTS).await)
}

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[sqlx::test(migrations = false)]
async fn migrations_apply_revert_and_apply_again_to_the_same_catalog(pool: PgPool) {
    MIGRATOR.run(&pool).await.unwrap();
    let first = catalog(&pool).await;
    MIGRATOR.run(&pool).await.unwrap();
    let unchanged = catalog(&pool).await;
    MIGRATOR.undo(&pool, 0).await.unwrap();
    let reverted = catalog(&pool).await;
    MIGRATOR.run(&pool).await.unwrap();
    let second = catalog(&pool).await;

    assert_eq!(unchanged, first);
    assert_eq!(reverted, Catalog::default());
    assert_eq!(second, first);
}

#[sqlx::test(migrations = false)]
async fn the_migration_creates_the_table_with_named_constraints(pool: PgPool) {
    MIGRATOR.run(&pool).await.unwrap();

    let (columns, constraints) = catalog(&pool).await;

    assert_eq!(
        columns,
        vec![
            strings(&["example_api_resources", "id", "uuid", "NO", "1"]),
            strings(&["example_api_resources", "name", "text", "NO", "2"]),
            strings(&["example_api_resources", "description", "text", "NO", "3"]),
        ]
    );
    let names: Vec<&str> = constraints.iter().map(|row| row[1].as_str()).collect();
    assert_eq!(
        names,
        vec![
            "example_api_resources_description_check",
            "example_api_resources_name_check",
            "example_api_resources_pkey",
        ]
    );
    assert_eq!(constraints[2][2], "p");
}

#[sqlx::test(migrations = false)]
async fn the_embedded_migrator_holds_one_reversible_migration(pool: PgPool) {
    MIGRATOR.run(&pool).await.unwrap();

    let applied: i64 = sqlx::query_scalar("SELECT count(*) FROM _sqlx_migrations")
        .fetch_one(&pool)
        .await
        .unwrap();

    assert_eq!(applied, 1);
    assert_eq!(
        MIGRATOR
            .iter()
            .filter(|migration| migration.migration_type.is_down_migration())
            .count(),
        1
    );
}

#[sqlx::test(migrations = false)]
async fn the_constraints_reject_an_empty_name_and_an_oversized_description(pool: PgPool) {
    MIGRATOR.run(&pool).await.unwrap();
    let insert = "INSERT INTO example_api_resources (id, name, description) VALUES (gen_random_uuid(), $1, $2)";

    let empty_name = sqlx::query(insert).bind("").bind("d").execute(&pool).await;
    let long_description = sqlx::query(insert)
        .bind("n")
        .bind("d".repeat(1025))
        .execute(&pool)
        .await;
    let valid = sqlx::query(insert)
        .bind("n")
        .bind("d".repeat(1024))
        .execute(&pool)
        .await;

    assert!(empty_name.is_err());
    assert!(long_description.is_err());
    assert!(valid.is_ok());
}

#[tokio::test]
async fn a_lazy_pool_is_created_and_fails_a_query_within_the_acquire_timeout() {
    let settings = PostgresSettings {
        url: support::DEAD_DATABASE_URL.to_owned(),
        max_connections: 1,
        acquire_timeout: Duration::from_millis(500),
        statement_timeout: Duration::from_secs(5),
    };
    let started = Instant::now();

    let pool = connect_lazy(&settings).unwrap();
    let created_in = started.elapsed();
    let result = tokio::time::timeout(
        Duration::from_secs(10),
        sqlx::query("SELECT 1").execute(&pool),
    )
    .await
    .expect("the query must give up on its own");

    assert!(created_in < Duration::from_millis(250));
    assert!(result.is_err());
    assert!(started.elapsed() < Duration::from_millis(1500));
}

#[tokio::test]
async fn a_query_succeeds_against_the_real_database_and_connections_carry_the_statement_timeout() {
    let settings = PostgresSettings {
        statement_timeout: Duration::from_millis(1500),
        ..support::postgres_settings()
    };
    let pool = connect_lazy(&settings).unwrap();

    let one: i32 = sqlx::query_scalar("SELECT 1")
        .fetch_one(&pool)
        .await
        .unwrap();
    let timeout: String = sqlx::query_scalar("SHOW statement_timeout")
        .fetch_one(&pool)
        .await
        .unwrap();

    assert_eq!(one, 1);
    assert_eq!(timeout, "1500ms");
}

#[tokio::test]
async fn an_out_of_range_statement_timeout_is_kept_within_what_the_server_accepts() {
    let tiny = PostgresSettings {
        statement_timeout: Duration::ZERO,
        ..support::postgres_settings()
    };
    let huge = PostgresSettings {
        statement_timeout: Duration::from_hours(60 * 24),
        ..support::postgres_settings()
    };

    let mut shown = Vec::new();
    for settings in [tiny, huge] {
        let pool = connect_lazy(&settings).unwrap();
        let timeout: String = sqlx::query_scalar("SHOW statement_timeout")
            .fetch_one(&pool)
            .await
            .unwrap();
        shown.push(timeout);
    }

    assert_eq!(shown, ["1ms", "24d"]);
}

#[tokio::test]
async fn a_statement_longer_than_the_statement_timeout_is_cancelled() {
    let settings = PostgresSettings {
        statement_timeout: Duration::from_millis(200),
        ..support::postgres_settings()
    };
    let pool = connect_lazy(&settings).unwrap();

    let result = sqlx::query("SELECT pg_sleep(3)").execute(&pool).await;

    assert!(result.is_err());
}

#[tokio::test]
async fn the_pool_never_holds_more_connections_than_max_connections() {
    let settings = PostgresSettings {
        max_connections: 1,
        acquire_timeout: Duration::from_millis(300),
        ..support::postgres_settings()
    };
    let pool = connect_lazy(&settings).unwrap();

    let held = pool.acquire().await.unwrap();
    let second = pool.acquire().await;
    drop(held);
    let third = pool.acquire().await;

    assert!(matches!(second, Err(sqlx::Error::PoolTimedOut)));
    assert!(third.is_ok());
}
