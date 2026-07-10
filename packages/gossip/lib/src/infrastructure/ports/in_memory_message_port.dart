import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'message_port.dart';

/// Transforms message bytes in flight, simulating corruption on a link.
typedef MessageTransform = Uint8List Function(Uint8List bytes);

/// Controls when [InMemoryMessageBus] hands a message to the destination.
enum BusDeliveryMode {
  /// `deliver()` adds the message to the destination's stream controller
  /// synchronously. The receiver still observes it asynchronously because
  /// ports use non-sync broadcast controllers, but the add itself happens
  /// within the sender's call stack.
  synchronous,

  /// `deliver()` schedules the add on the microtask queue, guaranteeing at
  /// least one event-loop yield between send and delivery. Link policies
  /// (drops, duplication, corruption, holds) are still evaluated
  /// synchronously at send time so behavior stays deterministic.
  asynchronous,
}

/// Per-direction network conditions for a (sender → destination) link.
class _LinkConditions {
  /// One-way partition: all messages on this link are dropped.
  bool blocked = false;

  /// Number of upcoming messages to drop unconditionally.
  int dropNextCount = 0;

  /// Probability [0, 1] of dropping each message; requires [dropRandom].
  double dropRate = 0.0;
  Random? dropRandom;

  /// Number of upcoming messages to deliver twice.
  int duplicateNextCount = 0;

  /// Probability [0, 1] of duplicating each message; requires
  /// [duplicateRandom].
  double duplicateRate = 0.0;
  Random? duplicateRandom;

  /// Byte transform applied to messages, simulating corruption.
  MessageTransform? corruption;

  /// Remaining messages to corrupt; null means corrupt indefinitely.
  int? corruptionRemaining;

  /// When true, messages are queued in [heldMessages] instead of delivered.
  bool holding = false;

  /// Messages queued while [holding], in send order.
  final List<Uint8List> heldMessages = [];

  /// True when every condition is at its default and nothing is queued,
  /// meaning the entry can be garbage-collected from the bus.
  bool get isNeutral =>
      !blocked &&
      dropNextCount == 0 &&
      dropRandom == null &&
      duplicateNextCount == 0 &&
      duplicateRandom == null &&
      corruption == null &&
      !holding &&
      heldMessages.isEmpty;
}

/// Shared message router for simulating network communication in-process.
///
/// [InMemoryMessageBus] acts as a central message router that delivers
/// messages between [InMemoryMessagePort] instances within the same process.
/// This enables testing multi-node gossip scenarios without requiring actual
/// network communication.
///
/// ## Usage
/// ```dart
/// final bus = InMemoryMessageBus();
/// final port1 = InMemoryMessagePort(NodeId('node1'), bus);
/// final port2 = InMemoryMessagePort(NodeId('node2'), bus);
///
/// // Messages sent via port1 can be received by port2
/// await port1.send(NodeId('node2'), bytes);
/// ```
///
/// The bus maintains a registry of active ports and routes messages to the
/// appropriate recipients based on destination [NodeId].
///
/// ## Simulating adverse network conditions
///
/// Per-link policies — keyed by the (sender, destination) direction, so each
/// direction of a pair is controlled independently — can degrade delivery:
///
/// - [blockLink]/[unblockLink]: one-way partition (asymmetric; the
///   bidirectional [unregister] partition semantics are unchanged).
/// - [dropNextMessages]/[setDropRate]: targeted or probabilistic loss.
///   Rates require an injectable seeded [Random] for determinism.
/// - [duplicateNextMessages]/[setDuplicateRate]: deliver messages twice.
/// - [corruptNextMessages]/[setLinkCorruption]: transform bytes in flight.
/// - [holdLink]/[flushHeldMessages]/[releaseLink]: latency simulation —
///   queue messages on a link and release them explicitly later.
///
/// Policies are evaluated in a fixed order at send time: registration check,
/// block, targeted drop, probabilistic drop, corruption, duplication, hold.
class InMemoryMessageBus {
  /// Creates a bus.
  ///
  /// [deliveryMode] defaults to [BusDeliveryMode.asynchronous]: sends are
  /// never observed synchronously by the receiver.
  InMemoryMessageBus({this.deliveryMode = BusDeliveryMode.asynchronous});

  /// How messages are handed to destination stream controllers.
  final BusDeliveryMode deliveryMode;

  final Map<NodeId, StreamController<IncomingMessage>> _ports = {};

  /// Conditions per directed link, keyed by (sender, destination).
  final Map<(NodeId, NodeId), _LinkConditions> _links = {};

  /// Registers a port for a node to receive messages.
  ///
  /// The controller will receive [IncomingMessage] instances when other
  /// nodes send messages to this node ID.
  void register(NodeId nodeId, StreamController<IncomingMessage> controller) {
    _ports[nodeId] = controller;
  }

  /// Unregisters a port, stopping message delivery to this node.
  void unregister(NodeId nodeId) {
    _ports.remove(nodeId);
  }

  // ---------------------------------------------------------------------
  // Link condition configuration
  // ---------------------------------------------------------------------

  /// Blocks all messages sent [from] → [to] (one-way partition).
  ///
  /// The reverse direction is unaffected; block both directions for a full
  /// partition, or use [unregister] for the legacy bidirectional partition.
  void blockLink(NodeId from, NodeId to) {
    _link(from, to).blocked = true;
  }

  /// Removes a one-way block previously set with [blockLink].
  void unblockLink(NodeId from, NodeId to) {
    final link = _links[(from, to)];
    if (link == null) return;
    link.blocked = false;
    _pruneIfNeutral(from, to);
  }

  /// Returns true if messages [from] → [to] are currently blocked.
  bool isLinkBlocked(NodeId from, NodeId to) =>
      _links[(from, to)]?.blocked ?? false;

  /// Drops the next [count] messages sent [from] → [to].
  ///
  /// Dropped messages consume the counter before duplication or corruption
  /// applies. Throws [ArgumentError] if [count] is not positive.
  void dropNextMessages(NodeId from, NodeId to, {int count = 1}) {
    if (count < 1) {
      throw ArgumentError.value(count, 'count', 'must be >= 1');
    }
    _link(from, to).dropNextCount += count;
  }

  /// Drops each message sent [from] → [to] with probability [rate].
  ///
  /// [random] must be a caller-provided (typically seeded) [Random] so the
  /// drop pattern is deterministic and reproducible. Throws [ArgumentError]
  /// if [rate] is outside [0, 1].
  void setDropRate(
    NodeId from,
    NodeId to,
    double rate, {
    required Random random,
  }) {
    if (rate < 0.0 || rate > 1.0) {
      throw ArgumentError.value(rate, 'rate', 'must be within [0, 1]');
    }
    final link = _link(from, to);
    link.dropRate = rate;
    link.dropRandom = random;
  }

  /// Removes a probabilistic drop rate previously set with [setDropRate].
  void clearDropRate(NodeId from, NodeId to) {
    final link = _links[(from, to)];
    if (link == null) return;
    link.dropRate = 0.0;
    link.dropRandom = null;
    _pruneIfNeutral(from, to);
  }

  /// Delivers the next [count] messages sent [from] → [to] twice.
  ///
  /// Throws [ArgumentError] if [count] is not positive.
  void duplicateNextMessages(NodeId from, NodeId to, {int count = 1}) {
    if (count < 1) {
      throw ArgumentError.value(count, 'count', 'must be >= 1');
    }
    _link(from, to).duplicateNextCount += count;
  }

  /// Duplicates each message sent [from] → [to] with probability [rate].
  ///
  /// [random] must be a caller-provided (typically seeded) [Random] so the
  /// duplication pattern is deterministic. Throws [ArgumentError] if [rate]
  /// is outside [0, 1].
  void setDuplicateRate(
    NodeId from,
    NodeId to,
    double rate, {
    required Random random,
  }) {
    if (rate < 0.0 || rate > 1.0) {
      throw ArgumentError.value(rate, 'rate', 'must be within [0, 1]');
    }
    final link = _link(from, to);
    link.duplicateRate = rate;
    link.duplicateRandom = random;
  }

  /// Removes a duplication rate previously set with [setDuplicateRate].
  void clearDuplicateRate(NodeId from, NodeId to) {
    final link = _links[(from, to)];
    if (link == null) return;
    link.duplicateRate = 0.0;
    link.duplicateRandom = null;
    _pruneIfNeutral(from, to);
  }

  /// Applies [transform] to the next [count] messages sent [from] → [to],
  /// simulating in-flight corruption.
  ///
  /// Replaces any corruption previously configured on the link. Throws
  /// [ArgumentError] if [count] is not positive.
  void corruptNextMessages(
    NodeId from,
    NodeId to,
    MessageTransform transform, {
    int count = 1,
  }) {
    if (count < 1) {
      throw ArgumentError.value(count, 'count', 'must be >= 1');
    }
    final link = _link(from, to);
    link.corruption = transform;
    link.corruptionRemaining = count;
  }

  /// Applies [transform] to every message sent [from] → [to] until
  /// [clearLinkCorruption] is called.
  ///
  /// Replaces any corruption previously configured on the link.
  void setLinkCorruption(NodeId from, NodeId to, MessageTransform transform) {
    final link = _link(from, to);
    link.corruption = transform;
    link.corruptionRemaining = null;
  }

  /// Removes any corruption configured on the [from] → [to] link.
  void clearLinkCorruption(NodeId from, NodeId to) {
    final link = _links[(from, to)];
    if (link == null) return;
    link.corruption = null;
    link.corruptionRemaining = null;
    _pruneIfNeutral(from, to);
  }

  // ---------------------------------------------------------------------
  // Held (in-flight) messages
  // ---------------------------------------------------------------------

  /// Holds all subsequent messages sent [from] → [to] in an in-flight queue
  /// instead of delivering them (latency simulation).
  ///
  /// Held messages are released explicitly via [flushHeldMessages] (link
  /// keeps holding) or [releaseLink] (link stops holding). While messages
  /// are held, the sending port's [InMemoryMessagePort.pendingSendCount]
  /// reflects the queued count.
  void holdLink(NodeId from, NodeId to) {
    _link(from, to).holding = true;
  }

  /// Delivers currently held messages, in original send order.
  ///
  /// With [from] and [to] given, flushes that link only; with neither,
  /// flushes every link. Links keep holding messages sent afterwards —
  /// use [releaseLink] to stop holding. Held messages whose destination has
  /// been unregistered are silently dropped (network unreachability).
  void flushHeldMessages({NodeId? from, NodeId? to}) {
    for (final entry in _links.entries) {
      final (linkFrom, linkTo) = entry.key;
      if (from != null && linkFrom != from) continue;
      if (to != null && linkTo != to) continue;
      final held = List<Uint8List>.of(entry.value.heldMessages);
      entry.value.heldMessages.clear();
      for (final bytes in held) {
        _dispatch(linkTo, linkFrom, bytes);
      }
    }
  }

  /// Stops holding the [from] → [to] link and delivers everything held.
  void releaseLink(NodeId from, NodeId to) {
    final link = _links[(from, to)];
    if (link == null) return;
    link.holding = false;
    flushHeldMessages(from: from, to: to);
    _pruneIfNeutral(from, to);
  }

  /// Number of messages currently held on the [from] → [to] link.
  int heldMessageCount(NodeId from, NodeId to) =>
      _links[(from, to)]?.heldMessages.length ?? 0;

  /// Total messages currently held across all links originating at [from].
  int totalHeldMessagesFrom(NodeId from) {
    var total = 0;
    for (final entry in _links.entries) {
      if (entry.key.$1 == from) total += entry.value.heldMessages.length;
    }
    return total;
  }

  // ---------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------

  /// Resets every condition on the [from] → [to] link, delivering any held
  /// messages first.
  void clearLinkConditions(NodeId from, NodeId to) {
    final link = _links[(from, to)];
    if (link == null) return;
    link.holding = false;
    flushHeldMessages(from: from, to: to);
    _links.remove((from, to));
  }

  /// Resets every condition on every link, delivering any held messages.
  void clearAllLinkConditions() {
    for (final (from, to) in _links.keys.toList()) {
      clearLinkConditions(from, to);
    }
  }

  // ---------------------------------------------------------------------
  // Delivery
  // ---------------------------------------------------------------------

  /// Delivers a message from sender to destination.
  ///
  /// If the destination or sender port is not registered or the destination
  /// is closed, the message is silently dropped (simulating network
  /// unreachability). Checking the sender ensures that partitioned nodes
  /// (unregistered via [unregister]) cannot send messages either, making
  /// partitions bidirectional.
  ///
  /// Any conditions configured on the (sender → destination) link are
  /// applied here, in a fixed order so tests are deterministic:
  /// block → targeted drop → probabilistic drop → corruption → duplication
  /// → hold.
  void deliver(NodeId destination, NodeId sender, Uint8List bytes) {
    if (!_ports.containsKey(sender)) return;

    final link = _links[(sender, destination)];
    var payload = bytes;
    var copies = 1;

    if (link != null) {
      if (link.blocked) return;

      if (link.dropNextCount > 0) {
        link.dropNextCount--;
        _pruneIfNeutral(sender, destination);
        return;
      }

      final dropRandom = link.dropRandom;
      if (dropRandom != null && dropRandom.nextDouble() < link.dropRate) {
        return;
      }

      final corruption = link.corruption;
      if (corruption != null) {
        payload = corruption(payload);
        final remaining = link.corruptionRemaining;
        if (remaining != null) {
          link.corruptionRemaining = remaining - 1;
          if (remaining - 1 <= 0) {
            link.corruption = null;
            link.corruptionRemaining = null;
          }
        }
      }

      if (link.duplicateNextCount > 0) {
        link.duplicateNextCount--;
        copies = 2;
      } else {
        final duplicateRandom = link.duplicateRandom;
        if (duplicateRandom != null &&
            duplicateRandom.nextDouble() < link.duplicateRate) {
          copies = 2;
        }
      }

      if (link.holding) {
        for (var i = 0; i < copies; i++) {
          link.heldMessages.add(payload);
        }
        return;
      }
    }

    for (var i = 0; i < copies; i++) {
      _dispatch(destination, sender, payload);
    }
  }

  /// Hands [bytes] to the destination's controller, honoring [deliveryMode].
  ///
  /// The destination is re-checked here so that held messages flushed after
  /// a partition ([unregister]) are dropped like any other in-flight
  /// traffic.
  void _dispatch(NodeId destination, NodeId sender, Uint8List bytes) {
    final controller = _ports[destination];
    if (controller == null || controller.isClosed) return;

    void add() {
      if (controller.isClosed) return;
      controller.add(
        IncomingMessage(
          sender: sender,
          bytes: bytes,
          receivedAt: DateTime.now(),
        ),
      );
    }

    if (deliveryMode == BusDeliveryMode.synchronous) {
      add();
    } else {
      scheduleMicrotask(add);
    }
  }

  _LinkConditions _link(NodeId from, NodeId to) =>
      _links.putIfAbsent((from, to), _LinkConditions.new);

  /// Drops the bookkeeping entry for a link once all conditions are reset,
  /// keeping the common no-conditions path allocation-free.
  void _pruneIfNeutral(NodeId from, NodeId to) {
    final link = _links[(from, to)];
    if (link != null && link.isNeutral) {
      _links.remove((from, to));
    }
  }
}

/// In-memory implementation of [MessagePort] for testing.
///
/// Routes messages through a shared [InMemoryMessageBus] within the same
/// process, enabling multi-node testing without real network communication.
///
/// **Use only for testing.**
///
/// Messages sent via one port's [send] method are delivered to the
/// destination port's [incoming] stream if both ports share the same bus,
/// after at least one event-loop yield (see [BusDeliveryMode]).
///
/// This simulates a perfect network (no delays, packet loss, or reordering)
/// unless link conditions are configured on the bus (see
/// [InMemoryMessageBus] for one-way blocking, drops, duplication,
/// corruption, and held in-flight messages).
///
/// ## Backpressure Testing
///
/// [pendingSendCount] reflects messages genuinely held in flight by the bus
/// (via [InMemoryMessageBus.holdLink]) plus any simulated congestion set
/// through [setSimulatedPendingCount]:
/// ```dart
/// final port = InMemoryMessagePort(nodeId, bus);
/// port.setSimulatedPendingCount(15); // Simulate 15 pending messages
/// // GossipEngine will skip rounds due to congestion
/// ```
class InMemoryMessagePort implements MessagePort {
  /// The node ID this port represents.
  final NodeId localNode;

  /// The shared bus for message routing.
  final InMemoryMessageBus bus;

  final StreamController<IncomingMessage> _controller;

  /// Global simulated pending send count for backpressure testing.
  int _simulatedPendingCount = 0;

  /// Per-peer simulated pending send counts for backpressure testing.
  final Map<NodeId, int> _perPeerPendingCounts = {};

  /// Creates a port and registers it with the bus.
  InMemoryMessagePort(this.localNode, this.bus)
    : _controller = StreamController<IncomingMessage>.broadcast() {
    bus.register(localNode, _controller);
  }

  @override
  Future<void> send(
    NodeId destination,
    Uint8List bytes, {
    MessagePriority priority = MessagePriority.normal,
  }) async {
    // Priority is ignored in test implementation - messages delivered
    // according to the bus's delivery mode and link conditions.
    bus.deliver(destination, localNode, bytes);
  }

  @override
  Stream<IncomingMessage> get incoming => _controller.stream;

  @override
  Future<void> close() async {
    bus.unregister(localNode);
    await _controller.close();
  }

  /// Re-registers this port with the bus after being unregistered.
  ///
  /// Used by test infrastructure to simulate network healing after partition.
  /// Only works if the port hasn't been closed.
  void reregister() {
    if (!_controller.isClosed) {
      bus.register(localNode, _controller);
    }
  }

  /// Sets the global simulated pending send count for backpressure testing.
  ///
  /// Used as a fallback when no per-peer count is set for a given peer.
  /// Set to 0 to clear simulated congestion.
  void setSimulatedPendingCount(int count) {
    _simulatedPendingCount = count;
  }

  /// Sets the simulated pending send count for a specific peer.
  ///
  /// Overrides the global count for this peer. Set to 0 and remove with
  /// [clearSimulatedPendingCounts] to revert to the global fallback.
  void setSimulatedPendingCountForPeer(NodeId peer, int count) {
    _perPeerPendingCounts[peer] = count;
  }

  /// Clears all per-peer simulated pending counts.
  void clearSimulatedPendingCounts() {
    _perPeerPendingCounts.clear();
    _simulatedPendingCount = 0;
  }

  @override
  int pendingSendCount(NodeId peer) =>
      (_perPeerPendingCounts[peer] ?? _simulatedPendingCount) +
      bus.heldMessageCount(localNode, peer);

  @override
  int get totalPendingSendCount {
    final held = bus.totalHeldMessagesFrom(localNode);
    if (_perPeerPendingCounts.isNotEmpty) {
      return _perPeerPendingCounts.values.fold(held, (sum, v) => sum + v);
    }
    return _simulatedPendingCount + held;
  }
}
