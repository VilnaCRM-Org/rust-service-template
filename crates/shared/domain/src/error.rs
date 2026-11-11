//! Error alias used at port boundaries.

/// A boxed error that can cross threads.
pub type BoxError = Box<dyn std::error::Error + Send + Sync + 'static>;
