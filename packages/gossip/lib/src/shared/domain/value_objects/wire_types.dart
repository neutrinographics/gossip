/// Wire type-byte partition. Membership owns 0-2, sync owns 3-6. The
/// partition test asserts no overlap; changing an existing value is a
/// wire-format break and is forbidden.
abstract final class WireTypes {
  static const int ping = 0;
  static const int ack = 1;
  static const int pingReq = 2;
  static const int digestRequest = 3;
  static const int digestResponse = 4;
  static const int deltaRequest = 5;
  static const int deltaResponse = 6;

  static const Set<int> membership = {ping, ack, pingReq};
  static const Set<int> sync = {
    digestRequest,
    digestResponse,
    deltaRequest,
    deltaResponse,
  };

  /// Union of every type byte owned by any current bounded context.
  ///
  /// Lets a per-context codec's `decode` distinguish a genuinely unknown
  /// (corrupt) type byte — outside [known] entirely — from a byte that
  /// belongs to a sibling context's family (in [known], just not this
  /// codec's own set): the former must throw (malformed frame), the latter
  /// must answer null ("not mine", routine traffic to ignore). Referencing
  /// this shared constant is not a context-to-context dependency — it's the
  /// same envelope-partition agreement both families already publish here.
  static const Set<int> known = {...membership, ...sync};
}
