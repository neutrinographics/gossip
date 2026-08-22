import 'dart:typed_data';

import 'package:gossip/gossip.dart';

/// Application-owned seam between message transport adapters and the
/// connection service (ARCH3-4). Mirrors gossip_bluey's dispatcher seam;
/// the interface lives in the application layer so infrastructure
/// depends inward, never the reverse.
abstract interface class MessageDispatcher {
  /// Sends a gossip message to a destination peer.
  ///
  /// Messages are queued by priority. High-priority messages (SWIM
  /// pings/acks) are processed before normal-priority messages (gossip
  /// data) to ensure failure detection isn't delayed during congestion.
  Future<void> sendGossipMessage(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  });

  /// Broadcast stream of decoded inbound gossip messages. REPLACES the
  /// mutable `onGossipMessage` callback slot.
  Stream<IncomingMessage> get incomingMessages;

  /// Returns the number of messages waiting to be sent to a specific peer.
  int pendingSendCount(NodeId peer);

  /// Returns the total number of messages waiting to be sent across all peers.
  int get totalPendingSendCount;
}
