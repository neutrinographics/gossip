/// The wire dialect this node EMITS. Receivers always accept every
/// registered version regardless of this setting — only send is gated,
/// so a mixed fleet keeps interoperating while configs are rolled out.
///
/// Framing only — each context's own emission strategy (e.g.
/// `sync/infrastructure/sync_wire_emission.dart`) owns what its payload
/// schema does with the version.
enum WireVersion {
  /// Legacy unprefixed frames: `[type byte][JSON]`.
  v1,

  /// Prefixed frames: `[0xF2][type byte][JSON]`.
  v2,
}
