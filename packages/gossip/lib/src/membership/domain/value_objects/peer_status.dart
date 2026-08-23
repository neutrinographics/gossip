/// Reachability status for a peer in SWIM failure detection.
///
/// Lifecycle progression:
/// - **reachable**: Peer responds to probes (healthy)
/// - **suspected**: ≥ failureThreshold consecutive failed probe rounds
/// - **unreachable**: ≥ unreachableThreshold consecutive failed probe rounds
///
/// Thresholds and transitions live in FailureDetector.
enum PeerStatus { reachable, suspected, unreachable }
