/// Wire type-byte partition (Part 2 spec). Membership owns 0-2, sync owns
/// 3-6. The partition test asserts no overlap; changing an existing value
/// is a wire-format break and is forbidden.
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
}
