//! Repository port of the example context.

use shared_domain::{BoxError, PageRequest};

use crate::aggregate::ExampleApiResource;
use crate::value_object::id::ExampleApiResourceId;

/// A repository operation failed.
#[derive(Debug, thiserror::Error)]
pub enum RepositoryError {
    /// A resource with the same identifier is already stored.
    #[error("the resource already exists")]
    AlreadyExists,
    /// The storage cannot be reached or answered with a failure.
    #[error("the repository is unavailable")]
    Unavailable(#[source] BoxError),
}

/// Stores `ExampleApiResource` aggregates.
#[async_trait::async_trait]
pub trait ExampleApiResourceRepository: std::fmt::Debug + Send + Sync {
    /// Inserts a new resource.
    ///
    /// # Errors
    ///
    /// [`RepositoryError::AlreadyExists`] when the identifier is stored, and
    /// [`RepositoryError::Unavailable`] when the storage fails.
    async fn save(&self, resource: &ExampleApiResource) -> Result<(), RepositoryError>;

    /// Finds a resource by identifier.
    ///
    /// # Errors
    ///
    /// [`RepositoryError::Unavailable`] when the storage fails.
    async fn find_by_id(
        &self,
        id: ExampleApiResourceId,
    ) -> Result<Option<ExampleApiResource>, RepositoryError>;

    /// Returns one page of resources ordered by identifier, newest first (descending).
    ///
    /// # Errors
    ///
    /// [`RepositoryError::Unavailable`] when the storage fails.
    async fn find_page(
        &self,
        page: PageRequest,
    ) -> Result<Vec<ExampleApiResource>, RepositoryError>;
}

#[cfg(test)]
mod tests {
    use std::error::Error as _;

    use super::RepositoryError;

    #[test]
    fn displays_and_chains_its_errors() {
        let unavailable = RepositoryError::Unavailable("disk on fire".into());

        assert_eq!(
            RepositoryError::AlreadyExists.to_string(),
            "the resource already exists"
        );
        assert_eq!(unavailable.to_string(), "the repository is unavailable");
        assert_eq!(unavailable.source().unwrap().to_string(), "disk on fire");
        assert!(RepositoryError::AlreadyExists.source().is_none());
    }
}
