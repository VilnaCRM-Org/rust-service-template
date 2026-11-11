//! `service healthcheck`: requests `/ping` on the loopback interface, with no dependency access.

use std::io::{Read as _, Write as _};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::process::ExitCode;
use std::time::Duration;

use crate::cli::HealthcheckArgs;

/// Connect, write and read timeout of the probe.
const TIMEOUT: Duration = Duration::from_secs(2);

/// Port probed when neither `--port` nor `APP_PORT` is given.
const DEFAULT_PORT: u16 = 8081;

/// Sends `GET /ping` over a plain TCP connection and reports whether the status line is 200.
#[expect(
    clippy::disallowed_methods,
    reason = "the liveness probe owns this loopback connection"
)]
fn probe(port: u16) -> std::io::Result<bool> {
    let address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let mut stream = TcpStream::connect_timeout(&address, TIMEOUT)?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    stream.write_all(b"GET /ping HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")?;
    let mut response = String::new();
    stream.read_to_string(&mut response)?;
    Ok(response.starts_with("HTTP/1.1 200"))
}

/// Requests `/ping` on `127.0.0.1:<port>`: 0 when the answer is 200, 1 otherwise (including an
/// unparsable port, a refused connection and a timeout). Prints nothing.
#[must_use]
pub fn run(args: &HealthcheckArgs) -> ExitCode {
    let port = args.port.as_deref().map_or(Ok(DEFAULT_PORT), str::parse);
    match port.map(probe) {
        Ok(Ok(true)) => ExitCode::SUCCESS,
        _ => ExitCode::FAILURE,
    }
}
