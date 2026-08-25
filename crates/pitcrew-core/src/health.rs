//! Asking a component whether it is actually ready.
//!
//! An open port is not readiness: a Spring app binds long before it can serve a
//! request, and calling that "up" sends people to a URL that 503s. When a
//! component configures a health path, that endpoint has the final say.
//!
//! The convention is Spring Boot Actuator's: a body containing `"UP"`. Written
//! by hand over a raw socket rather than with an HTTP client, because the whole
//! request is twelve lines and the alternative is a dependency tree for one
//! GET on localhost.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

/// Probe `http://127.0.0.1:<port><path>` and report whether it says UP.
///
/// Every failure — refused, timed out, a 500, a body that says DOWN — is the
/// same answer to the only question being asked: not ready yet. The distinction
/// matters for a human reading a log, not for the state machine.
pub fn probe(port: u16, path: &str, timeout: Duration) -> bool {
    let Ok(mut addrs) = ("127.0.0.1", port).to_socket_addrs() else {
        return false;
    };
    let Some(addr) = addrs.next() else {
        return false;
    };
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, timeout) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));

    let path = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    };
    // HTTP/1.0 so the server closes the connection itself and the read below
    // ends without having to parse a content length.
    let request =
        format!("GET {path} HTTP/1.0\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }

    // Capped: a health endpoint that streams megabytes is misconfigured, and
    // reading it all would stall the caller rather than answer the question.
    let mut body = Vec::with_capacity(4096);
    let mut chunk = [0u8; 1024];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                body.extend_from_slice(&chunk[..n]);
                if body.len() > 64 * 1024 {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    String::from_utf8_lossy(&body).contains("UP")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::BufRead;
    use std::net::TcpListener;

    /// Serves one request and stops. Returns the port.
    fn serve_once(response: &'static str) -> u16 {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            if let Ok((mut sock, _)) = listener.accept() {
                // Drain the request line so the client's write completes.
                let mut reader = std::io::BufReader::new(sock.try_clone().unwrap());
                let mut line = String::new();
                while reader.read_line(&mut line).unwrap_or(0) > 0 {
                    if line == "\r\n" || line == "\n" {
                        break;
                    }
                    line.clear();
                }
                let _ = sock.write_all(response.as_bytes());
            }
        });
        port
    }

    #[test]
    fn a_body_saying_up_is_up() {
        let port = serve_once("HTTP/1.0 200 OK\r\n\r\n{\"status\":\"UP\"}");
        assert!(probe(port, "/health", Duration::from_secs(2)));
    }

    /// The distinction between DOWN and unreachable matters to a person
    /// reading a log, not to the question being asked here.
    #[test]
    fn a_body_saying_anything_else_is_not_up() {
        let port = serve_once("HTTP/1.0 200 OK\r\n\r\n{\"status\":\"DOWN\"}");
        assert!(!probe(port, "/health", Duration::from_secs(2)));
    }

    /// A port that binds long before it can serve is exactly the case this
    /// exists for — nothing listening at all must not read as ready.
    #[test]
    fn nothing_listening_is_not_up() {
        let l = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = l.local_addr().unwrap().port();
        drop(l);
        assert!(!probe(port, "/health", Duration::from_millis(200)));
    }

    #[test]
    fn a_path_without_a_leading_slash_still_works() {
        let port = serve_once("HTTP/1.0 200 OK\r\n\r\nUP");
        assert!(probe(port, "health", Duration::from_secs(2)));
    }
}
