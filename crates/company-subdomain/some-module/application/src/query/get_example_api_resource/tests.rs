use std::sync::Arc;

use shared_domain::{Query as _, QueryHandler as _, Uuid};
use some_module_domain::{
    ExampleApiResource, ExampleApiResourceDescription, ExampleApiResourceId,
    ExampleApiResourceName, ExampleApiResourceRepository as _,
};
use test_support::repository::InMemoryExampleApiResourceRepository;

use super::{GetExampleApiResource, GetExampleApiResourceHandler};
use crate::error::ExampleApiResourceError;
use crate::query::ExampleApiResourceView;

fn id(counter: u128) -> Uuid {
    Uuid::from_uuid(uuid::Uuid::from_u128(counter))
}

async fn handler_over(
    repository: InMemoryExampleApiResourceRepository,
) -> GetExampleApiResourceHandler {
    let resource = ExampleApiResource::restore(
        ExampleApiResourceId::new(id(1)),
        ExampleApiResourceName::new("Name".to_owned()).unwrap(),
        ExampleApiResourceDescription::new("Description".to_owned()).unwrap(),
    );
    let _stored = repository.save(&resource).await;
    GetExampleApiResourceHandler::new(Arc::new(repository))
}

#[test]
fn the_query_is_named_after_its_type() {
    assert_eq!(GetExampleApiResource::NAME, "GetExampleApiResource");
}

#[tokio::test]
async fn a_stored_id_answers_its_view() {
    let handler = handler_over(InMemoryExampleApiResourceRepository::new()).await;

    let answer = handler
        .handle(GetExampleApiResource { id: id(1) })
        .await
        .unwrap();

    assert_eq!(
        answer,
        Some(ExampleApiResourceView {
            id: id(1),
            name: "Name".to_owned(),
            description: "Description".to_owned(),
        })
    );
}

#[tokio::test]
async fn an_unknown_id_answers_none() {
    let handler = handler_over(InMemoryExampleApiResourceRepository::new()).await;

    let answer = handler
        .handle(GetExampleApiResource { id: id(2) })
        .await
        .unwrap();

    assert_eq!(answer, None);
}

#[tokio::test]
async fn a_failing_repository_is_a_storage_error() {
    let handler = handler_over(InMemoryExampleApiResourceRepository::failing()).await;

    let error = handler
        .handle(GetExampleApiResource { id: id(1) })
        .await
        .unwrap_err();

    assert!(matches!(error, ExampleApiResourceError::Storage(_)));
}
