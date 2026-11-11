//! Cache probe.

use std::sync::Arc;
use std::time::Duration;

use health_check_domain::{Dependency, HealthProbe};
use shared_domain::{BoxError, Cache};

const KEY: &str = "health_check";
const VALUE: &[u8] = b"ok";
const TTL: Duration = Duration::from_secs(60);

/// Checks that the cache keeps what it is given: writes a value, reads it back and compares.
#[derive(Debug, Clone)]
pub struct CacheProbe {
    cache: Arc<dyn Cache>,
}

impl CacheProbe {
    /// Creates a probe over the cache of the service.
    #[must_use]
    pub const fn new(cache: Arc<dyn Cache>) -> Self {
        Self { cache }
    }
}

#[async_trait::async_trait]
impl HealthProbe for CacheProbe {
    fn dependency(&self) -> Dependency {
        Dependency::Cache
    }

    async fn check(&self) -> Result<(), BoxError> {
        self.cache.set(KEY, VALUE.to_vec(), TTL).await?;
        match self.cache.get(KEY).await? {
            Some(stored) if stored == VALUE => Ok(()),
            Some(_) => Err("the cache returned a different value than the one stored".into()),
            None => Err("the cache did not return the value that was stored".into()),
        }
    }
}

#[cfg(test)]
mod tests;
