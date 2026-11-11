//! Example bounded context, application layer: the command and query handlers, the event
//! subscriber, the application errors and the HTTP and GraphQL adapters of the example resource.
//!
//! The use-case modules (`command`, `query`, `subscriber`, `error`) must not import `axum`,
//! `utoipa` or `async_graphql`; only `http` and `graphql` may.
