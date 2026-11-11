//! Integration tests of the service binary: it is spawned as a process, with a cleared environment.

#[cfg(test)]
mod check_config;
#[cfg(test)]
mod migrate;
#[cfg(test)]
mod support;
