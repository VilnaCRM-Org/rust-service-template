use std::sync::Arc;
use std::time::Duration;

use shared_domain::Cache;
use shared_infrastructure::cache::MokaCache;

const LONG: Duration = Duration::from_secs(3600);
const SHORT: Duration = Duration::from_millis(150);
const PAST_SHORT: Duration = Duration::from_millis(400);

#[tokio::test]
async fn a_value_is_gone_after_its_ttl() {
    let cache: Arc<dyn Cache> = Arc::new(MokaCache::new());

    cache.set("key", b"value".to_vec(), SHORT).await.unwrap();
    let before = cache.get("key").await.unwrap();
    tokio::time::sleep(PAST_SHORT).await;
    let after = cache.get("key").await.unwrap();

    assert_eq!(before, Some(b"value".to_vec()));
    assert_eq!(after, None);
}

#[tokio::test]
async fn overwriting_a_key_replaces_its_ttl() {
    let cache: Arc<dyn Cache> = Arc::new(MokaCache::new());

    cache.set("shortened", b"v".to_vec(), LONG).await.unwrap();
    cache.set("shortened", b"v".to_vec(), SHORT).await.unwrap();
    cache.set("lengthened", b"v".to_vec(), SHORT).await.unwrap();
    cache.set("lengthened", b"v".to_vec(), LONG).await.unwrap();
    tokio::time::sleep(PAST_SHORT).await;

    assert_eq!(cache.get("shortened").await.unwrap(), None);
    assert_eq!(cache.get("lengthened").await.unwrap(), Some(b"v".to_vec()));
}
