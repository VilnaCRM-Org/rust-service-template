//! End-to-end suite: the Gherkin runner for the features of the repository.

#[cfg(test)]
mod steps;
#[cfg(test)]
mod world;

use cucumber::World as _;
use world::AppWorld;

#[tokio::main]
async fn main() {
    world::drop_leftover_databases().await;
    AppWorld::cucumber()
        .max_concurrent_scenarios(8)
        .fail_on_skipped()
        .after(|_feature, _rule, _scenario, _event, world| {
            Box::pin(async move {
                if let Some(world) = world {
                    world.drop_database().await;
                }
            })
        })
        .run_and_exit(concat!(env!("CARGO_MANIFEST_DIR"), "/../../features"))
        .await;
}
