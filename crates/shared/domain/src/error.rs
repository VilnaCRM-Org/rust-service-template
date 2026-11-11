//! Error alias used at port boundaries and the formatter of an error chain.

/// A boxed error that can cross threads.
pub type BoxError = Box<dyn std::error::Error + Send + Sync + 'static>;

/// Formats `cause` and every error behind it, outermost first, joined by `": "`.
///
/// Many SDK errors have a fixed top-level text (`service error`, `dispatch failure`) and keep the
/// real reason in their source, so a log entry that must say what went wrong formats the chain.
#[must_use]
pub fn error_chain(cause: &(dyn std::error::Error + 'static)) -> String {
    std::iter::successors(Some(cause), |error| error.source())
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(": ")
}

#[cfg(test)]
mod tests {
    use super::error_chain;

    #[derive(Debug, thiserror::Error)]
    enum Failure {
        #[error("dispatch failure")]
        Dispatch(#[source] Box<Self>),
        #[error("connection refused")]
        Refused,
    }

    #[test]
    fn a_chain_lists_every_error_outermost_first() {
        let cause = Failure::Dispatch(Box::new(Failure::Dispatch(Box::new(Failure::Refused))));

        assert_eq!(
            error_chain(&cause),
            "dispatch failure: dispatch failure: connection refused"
        );
    }

    #[test]
    fn an_error_without_a_source_is_its_own_text() {
        assert_eq!(error_chain(&Failure::Refused), "connection refused");
    }
}
