//! Seeded random generator.

use rand::SeedableRng as _;
use rand::rngs::StdRng;

/// The environment variable that carries the seed.
const SEED_VARIABLE: &str = "TEST_SEED";

/// A generator whose seed is printed when a test panics, so the failure can be reproduced with
/// `TEST_SEED=<seed>`.
#[derive(Debug)]
pub struct TestRng {
    seed: u64,
    rng: StdRng,
}

impl TestRng {
    /// Reads the seed from `TEST_SEED`. Cargo supplies the seed recorded in `.cargo/config.toml`
    /// unless the caller sets another one.
    ///
    /// # Panics
    ///
    /// Panics with a message that names `TEST_SEED` when the variable is unset or is not an
    /// unsigned 64-bit integer; no seed is ever drawn silently.
    #[must_use]
    #[expect(
        clippy::panic,
        reason = "a test run without a usable seed must fail loudly and name TEST_SEED"
    )]
    pub fn from_env() -> Self {
        match parse_seed(read_seed().as_deref()) {
            Ok(seed) => Self::from_seed(seed),
            Err(message) => panic!("{message}"),
        }
    }

    /// A generator with a known seed.
    #[must_use]
    pub fn from_seed(seed: u64) -> Self {
        Self {
            seed,
            rng: StdRng::seed_from_u64(seed),
        }
    }

    /// The seed.
    #[must_use]
    pub const fn seed(&self) -> u64 {
        self.seed
    }

    /// The wrapped generator, for `fake_with_rng` and the `rand` traits.
    pub const fn rng(&mut self) -> &mut StdRng {
        &mut self.rng
    }

    /// Writes the line that names the seed.
    fn report(&self, out: &mut impl std::io::Write) -> std::io::Result<()> {
        writeln!(out, "{SEED_VARIABLE}={}", self.seed)
    }
}

impl Drop for TestRng {
    fn drop(&mut self) {
        if std::thread::panicking() {
            let _result: std::io::Result<()> = self.report(&mut std::io::stderr());
        }
    }
}

#[expect(
    clippy::disallowed_methods,
    reason = "the seed is the one variable the test support reads from the environment"
)]
fn read_seed() -> Option<String> {
    std::env::var(SEED_VARIABLE).ok()
}

fn parse_seed(raw: Option<&str>) -> Result<u64, &'static str> {
    let raw =
        raw.ok_or("TEST_SEED is not set; run through cargo or set TEST_SEED=<unsigned integer>")?;
    raw.trim()
        .parse()
        .map_err(|_error| "TEST_SEED must be an unsigned 64-bit integer")
}

#[cfg(test)]
mod tests;
