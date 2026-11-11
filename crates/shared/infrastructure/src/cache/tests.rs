use std::sync::Arc;
use std::time::Duration;

use moka::Expiry as _;
use shared_domain::Cache;

use super::{Entry, EntryExpiry, MokaCache};

const LONG: Duration = Duration::from_secs(3600);

fn now() -> std::time::Instant {
    tokio::time::Instant::now().into_std()
}

fn entry(ttl: Duration) -> Entry {
    Entry {
        value: b"v".to_vec(),
        ttl,
    }
}

#[tokio::test]
async fn reads_back_what_was_set() {
    let cache: Arc<dyn Cache> = Arc::new(MokaCache::new());

    cache.set("key", b"value".to_vec(), LONG).await.unwrap();

    assert_eq!(cache.get("key").await.unwrap(), Some(b"value".to_vec()));
}

#[tokio::test]
async fn reads_nothing_for_an_unknown_key() {
    let cache = MokaCache::default();

    assert_eq!(cache.get("missing").await.unwrap(), None);
}

#[tokio::test]
async fn overwrites_the_value_of_a_key() {
    let cache = MokaCache::new();

    cache.set("key", b"one".to_vec(), LONG).await.unwrap();
    cache.set("key", b"two".to_vec(), LONG).await.unwrap();

    assert_eq!(cache.get("key").await.unwrap(), Some(b"two".to_vec()));
}

#[test]
fn an_entry_lives_for_the_ttl_it_was_stored_with() {
    let ttl = Duration::from_secs(7);

    assert_eq!(
        EntryExpiry.expire_after_create(&"k".to_owned(), &entry(ttl), now()),
        Some(ttl)
    );
}

#[test]
fn an_overwritten_entry_lives_for_its_new_ttl() {
    let ttl = Duration::from_secs(9);

    let expiry = EntryExpiry.expire_after_update(
        &"k".to_owned(),
        &entry(ttl),
        now(),
        Some(Duration::from_secs(1)),
    );

    assert_eq!(expiry, Some(ttl));
}

#[tokio::test]
async fn debug_names_the_type_and_counts_the_entries_without_printing_values() {
    let cache = MokaCache::new();
    assert_eq!(format!("{cache:?}"), "MokaCache { entries: 0 }");

    cache
        .set("secret-key", b"secret-value".to_vec(), LONG)
        .await
        .unwrap();
    cache.entries.run_pending_tasks().await;
    let text = format!("{cache:?}");

    assert_eq!(text, "MokaCache { entries: 1 }");
    assert!(!text.contains("secret"));
}
