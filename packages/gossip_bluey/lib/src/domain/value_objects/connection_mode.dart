/// Policy for what gossip_bluey does with peers surfaced by the scanner.
enum ConnectionMode {
  /// Default. Discovered peers are exposed via the candidates stream but
  /// no connection is initiated until the consumer explicitly calls
  /// `BlueyTransport.connectTo`.
  manual,

  /// Every discovered candidate (subject to backoff, dedup, and the
  /// target-connections cap) triggers an automatic
  /// `connectAndIdentify` attempt — mesh topology.
  auto,
}
