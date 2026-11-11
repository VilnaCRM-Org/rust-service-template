//! Liveness: `GET /ping` answers `pong` and touches no dependency (AD-12).

use std::future::Ready;

/// Answers `pong` as `text/plain; charset=utf-8`.
///
/// The handler takes no state, so it keeps answering while every dependency is down.
pub fn ping() -> Ready<&'static str> {
    std::future::ready("pong")
}

#[cfg(test)]
mod tests;
