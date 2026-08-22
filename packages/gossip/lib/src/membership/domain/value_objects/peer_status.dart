/// Reachability status for a peer in SWIM failure detection.
///
/// Lifecycle progression:
/// - **reachable**: Peer responds to probes (healthy)
/// - **suspected**: Probe failed, indirect probe in progress
/// - **unreachable**: Confirmed failed (direct and indirect probes failed)
enum PeerStatus { reachable, suspected, unreachable }
