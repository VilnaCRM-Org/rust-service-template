//! Seeded random generator.

use rand::SeedableRng as _;
use rand::rngs::StdRng;

/// The environment variable that carries the seed.
const SEED_VARIABLE: &str = "TEST_SEED";

/// A generator whose seed is printed when a test panics, so the failure can be reproduced with
/// `TEST_SEED=<seed>`.
#[derive(Debug)]
pub struct TestRng {
    rng: StdRng,
    report: PanicReport<std::io::Stderr>,
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
            rng: StdRng::seed_from_u64(seed),
            report: PanicReport::new(seed, std::io::stderr()),
        }
    }

    /// The seed.
    #[must_use]
    pub const fn seed(&self) -> u64 {
        self.report.seed
    }

    /// The wrapped generator, for `fake_with_rng` and the `rand` traits.
    pub const fn rng(&mut self) -> &mut StdRng {
        &mut self.rng
    }
}

/// Writes the line that names the seed when it is dropped while a panic unwinds. The writer is a type
/// parameter so that a test can read what is written; the generator uses the standard error stream.
#[derive(Debug)]
struct PanicReport<W: std::io::Write> {
    seed: u64,
    out: W,
}

impl<W: std::io::Write> PanicReport<W> {
    const fn new(seed: u64, out: W) -> Self {
        Self { seed, out }
    }

    /// Writes the line that names the seed.
    fn report(&mut self) -> std::io::Result<()> {
        writeln!(self.out, "{SEED_VARIABLE}={}", self.seed)
    }
}

impl<W: std::io::Write> Drop for PanicReport<W> {
    fn drop(&mut self) {
        if std::thread::panicking() {
            let _result: std::io::Result<()> = self.report();
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
