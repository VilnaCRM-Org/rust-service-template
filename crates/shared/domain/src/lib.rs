//! Shared kernel, domain layer: the aggregate and event abstractions, the command, query and event
//! bus ports, the technical ports (cache, clock, UUID generator) and the value objects that every
//! bounded context uses.
//!
//! This crate is framework-free: it depends on other domain crates and on the few third-party crates
//! that `architecture.toml` lists for the domain layer, and on nothing else.
