use rand::RngExt as _;

use super::{TestRng, parse_seed};

fn draw_ten(rng: &mut TestRng) -> Vec<u64> {
    (0..10).map(|_index| rng.rng().random::<u64>()).collect()
}

#[test]
fn two_generators_with_the_same_seed_draw_the_same_values() {
    let mut first = TestRng::from_seed(42);
    let mut second = TestRng::from_seed(42);

    assert_eq!(draw_ten(&mut first), draw_ten(&mut second));
}

#[test]
fn generators_with_different_seeds_draw_different_values() {
    let mut first = TestRng::from_seed(42);
    let mut second = TestRng::from_seed(43);

    assert_ne!(draw_ten(&mut first), draw_ten(&mut second));
}

#[test]
fn from_env_is_reproducible_and_reports_its_seed() {
    let mut first = TestRng::from_env();
    let mut second = TestRng::from_env();

    assert_eq!(first.seed(), second.seed());
    assert_eq!(draw_ten(&mut first), draw_ten(&mut second));
}

#[test]
fn parses_an_unsigned_integer() {
    assert_eq!(parse_seed(Some("42")), Ok(42));
    assert_eq!(parse_seed(Some(" 7\n")), Ok(7));
    assert_eq!(parse_seed(Some("18446744073709551615")), Ok(u64::MAX));
}

#[test]
fn a_missing_seed_names_the_variable() {
    let message = parse_seed(None).unwrap_err();

    assert!(message.contains("TEST_SEED"));
}

#[test]
fn an_invalid_seed_names_the_variable() {
    for raw in ["", "abc", "-1", "1.5", "18446744073709551616"] {
        let message = parse_seed(Some(raw)).unwrap_err();

        assert!(message.contains("TEST_SEED"), "{raw}");
    }
}

#[test]
fn the_report_is_the_seed_line() {
    let rng = TestRng::from_seed(7);
    let mut out = Vec::new();

    rng.report(&mut out).unwrap();

    assert_eq!(String::from_utf8(out).unwrap(), "TEST_SEED=7\n");
}

#[test]
fn dropping_while_panicking_does_not_abort() {
    let result = std::panic::catch_unwind(|| {
        let _rng = TestRng::from_seed(7);
        std::panic::panic_any("a test failure");
    });

    assert!(result.is_err());
}
