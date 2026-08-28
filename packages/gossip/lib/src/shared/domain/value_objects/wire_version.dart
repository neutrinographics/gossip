/// The wire dialect this node EMITS. Receivers always accept every
/// registered version regardless of this setting — only send is gated,
/// so a mixed fleet keeps interoperating while configs are rolled out.
enum WireVersion {
  /// Legacy unprefixed frames: `[type byte][JSON]`. Entry payloads are
  /// JSON int arrays and DeltaResponse never carries `hasMore`
  /// (continuation degrades to later anti-entropy rounds). The additive
  /// `floor` field IS emitted so upgraded peers get compaction interop;
  /// legacy decoders ignore unknown keys.
  v1,

  /// Prefixed frames: `[0xF2][type byte][JSON]`. Base64 entry payloads,
  /// `hasMore` always present, `floor` when non-empty.
  v2,
}
