//! Which local TCP ports are listening, and who owns them.
//!
//! "Up" means the port is open — so this is on the hot path, and it is also
//! what makes the `external` state possible: something listening on a
//! component's port that pitcrew did not start.
//!
//! The bash version read `/proc/net/tcp` and matched local addresses against a
//! hand-written little-endian hex table (`0100007F`, `::ffff:127.0.0.1`, …)
//! because that is what a shell can do without forking. Here the addresses
//! arrive as `IpAddr` and the question is asked directly.

use std::collections::{HashMap, HashSet};
use std::net::IpAddr;

use netstat2::{AddressFamilyFlags, ProtocolFlags, ProtocolSocketInfo, TcpState};

/// The set of locally-reachable listening TCP ports, and their owning pids
/// where the OS will say.
#[derive(Debug, Default, Clone)]
pub struct Listening {
    ports: HashSet<u16>,
    owners: HashMap<u16, u32>,
}

impl Listening {
    /// Is anything listening on this port?
    pub fn is_open(&self, port: u16) -> bool {
        self.ports.contains(&port)
    }

    /// The pid holding this port, when the OS will say.
    ///
    /// It often will not: a socket owned by another user is visible but its pid
    /// is not, which is exactly the case where a developer has the same stack
    /// running under a second account. A `None` here means "open, owner
    /// unknown" and must not be read as "not open".
    pub fn owner(&self, port: u16) -> Option<u32> {
        self.owners.get(&port).copied()
    }

    pub fn len(&self) -> usize {
        self.ports.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ports.is_empty()
    }
}

/// Every listening TCP socket bound somewhere this machine can reach itself.
///
/// Returns an empty set rather than an error when the OS refuses to enumerate
/// sockets: a dashboard that draws with every service marked down is wrong, but
/// a dashboard that refuses to draw is worse, and `doctor` is where an
/// environment problem gets reported.
pub fn scan() -> Listening {
    let families = AddressFamilyFlags::IPV4 | AddressFamilyFlags::IPV6;
    let Ok(sockets) = netstat2::get_sockets_info(families, ProtocolFlags::TCP) else {
        return Listening::default();
    };

    let mut out = Listening::default();
    for socket in sockets {
        let ProtocolSocketInfo::Tcp(tcp) = &socket.protocol_socket_info else {
            continue;
        };
        if tcp.state != TcpState::Listen || !is_local(&tcp.local_addr) {
            continue;
        }
        out.ports.insert(tcp.local_port);
        // First pid wins. A listening socket with several associated pids is a
        // pre-forking server; any of them is a correct answer to "who do I stop",
        // and the tree walk from it covers the rest.
        if let Some(&pid) = socket.associated_pids.first() {
            out.owners.entry(tcp.local_port).or_insert(pid);
        }
    }
    out
}

/// Is a service bound to this address reachable from this machine?
///
/// Loopback and the wildcard both are. A socket bound to one specific external
/// interface is not what a local dev stack looks like, and counting it would
/// make a colleague's service on the LAN read as "your backend is up".
fn is_local(addr: &IpAddr) -> bool {
    match addr {
        IpAddr::V4(v4) => v4.is_loopback() || v4.is_unspecified(),
        IpAddr::V6(v6) => {
            v6.is_loopback()
                || v6.is_unspecified()
                // ::ffff:127.0.0.1 — a v4 loopback wearing a v6 address, which
                // is what a JVM binds when it is told "localhost" on a
                // dual-stack box. The bash version needed a hex literal for
                // this case; it is still a case.
                || v6.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback() || v4.is_unspecified())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr, TcpListener};

    #[test]
    fn loopback_and_wildcard_are_local() {
        assert!(is_local(&IpAddr::V4(Ipv4Addr::LOCALHOST)));
        assert!(is_local(&IpAddr::V4(Ipv4Addr::UNSPECIFIED)));
        assert!(is_local(&IpAddr::V6(Ipv6Addr::LOCALHOST)));
        assert!(is_local(&IpAddr::V6(Ipv6Addr::UNSPECIFIED)));
    }

    /// The dual-stack case: a JVM told "localhost" binds `::ffff:127.0.0.1`,
    /// and a check that only knew about `::1` would call that backend down.
    #[test]
    fn a_v4_mapped_loopback_is_local() {
        assert!(is_local(&IpAddr::V6(Ipv4Addr::LOCALHOST.to_ipv6_mapped())));
    }

    /// A service on the LAN is not this machine's service. Counting it would
    /// make a colleague's backend read as your own.
    #[test]
    fn an_address_on_another_interface_is_not_local() {
        assert!(!is_local(&IpAddr::V4(Ipv4Addr::new(192, 168, 1, 40))));
        assert!(!is_local(&IpAddr::V6(Ipv6Addr::new(
            0x2001, 0xdb8, 0, 0, 0, 0, 0, 1
        ))));
    }

    /// End to end against the real OS, both directions in one test.
    ///
    /// Deliberately NOT two tests. Cargo runs them in parallel threads, and an
    /// ephemeral port released by one is exactly the port the kernel is most
    /// likely to hand the other — so a separate "closed" test fails at random
    /// on a machine that is doing nothing wrong.
    #[test]
    fn a_bound_port_is_seen_and_a_released_one_is_not() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind");
        let port = listener.local_addr().unwrap().port();

        assert!(
            scan().is_open(port),
            "port {port} is bound by this test but the scan did not see it"
        );

        drop(listener);

        // Re-binding is the only honest way to establish that nothing is
        // listening: another process on this machine is free to take the port
        // the moment it is released, and asserting "closed" without checking
        // would blame the scanner for someone else's socket.
        match TcpListener::bind((Ipv4Addr::LOCALHOST, port)) {
            Ok(proof) => {
                drop(proof);
                assert!(!scan().is_open(port), "nothing is listening on {port}");
            }
            Err(_) => eprintln!("skipping the closed half: {port} was taken by something else"),
        }
    }
}
