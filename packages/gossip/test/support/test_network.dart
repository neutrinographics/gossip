import 'dart:math';
import 'dart:typed_data';

import 'package:gossip/src/facade/coordinator.dart';
import 'package:gossip/src/facade/coordinator_config.dart';
import 'package:gossip/src/domain/entities/peer.dart';
import 'package:gossip/src/domain/events/domain_event.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/stream_id.dart';
import 'package:gossip/src/domain/value_objects/log_entry.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_channel_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_local_node_repository.dart';
import 'package:gossip/src/infrastructure/repositories/in_memory_peer_repository.dart';
import 'package:gossip/src/infrastructure/stores/in_memory_entry_repository.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_time_port.dart';
import 'package:gossip/src/infrastructure/ports/in_memory_message_port.dart';

/// A test node wrapping a Coordinator with its infrastructure.
class TestNode {
  final NodeId id;
  final Coordinator coordinator;
  final InMemoryTimePort timePort;
  final InMemoryMessagePort messagePort;

  TestNode._({
    required this.id,
    required this.coordinator,
    required this.timePort,
    required this.messagePort,
  });
}

/// DSL for creating and managing test networks of gossip nodes.
///
/// Simplifies integration test setup by providing a fluent API for:
/// - Creating nodes with automatic infrastructure wiring
/// - Establishing peer connections (full mesh or custom topology)
/// - Creating channels and streams across nodes
/// - Triggering gossip/probe rounds
/// - Simulating network partitions
///
/// ## Example
/// ```dart
/// final network = await TestNetwork.create(['node1', 'node2', 'node3']);
/// network.connectAll();
///
/// await network.createChannel('chat', members: network.nodeIds);
/// await network['node1'].write('chat', 'messages', [1, 2, 3]);
///
/// await network.runRounds(5);
///
/// expect(await network['node2'].entryCount('chat', 'messages'), equals(1));
/// ```
class TestNetwork {
  final InMemoryMessageBus _messageBus;
  final Map<String, TestNode> _nodes;
  final Map<String, InMemoryMessagePort> _originalPorts;
  final Set<String> _partitionedNodes = {};

  TestNetwork._(this._messageBus, this._nodes, this._originalPorts);

  /// Creates a test network with the given node names.
  ///
  /// Each node gets its own Coordinator with in-memory infrastructure.
  /// Nodes are not connected by default - use [connect] or [connectAll].
  ///
  /// The optional [seed] parameter provides deterministic random number
  /// generation for peer selection, eliminating test flakiness from
  /// probabilistic gossip behavior.
  static Future<TestNetwork> create(
    List<String> nodeNames, {
    int seed = 42,
    CoordinatorConfig? config,
  }) async {
    final messageBus = InMemoryMessageBus();
    final nodes = <String, TestNode>{};
    final originalPorts = <String, InMemoryMessagePort>{};

    for (final name in nodeNames) {
      final nodeId = NodeId(name);
      final timePort = InMemoryTimePort();
      final messagePort = InMemoryMessagePort(nodeId, messageBus);

      // Each node gets its own seeded Random for deterministic peer selection.
      // Using different seeds per node (based on index) ensures varied but
      // reproducible behavior across nodes.
      final nodeIndex = nodeNames.indexOf(name);
      final random = Random(seed + nodeIndex);

      final coordinator = await Coordinator.create(
        localNodeRepository: InMemoryLocalNodeRepository(nodeId: nodeId),
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: messagePort,
        timerPort: timePort,
        random: random,
        config: config,
      );

      nodes[name] = TestNode._(
        id: nodeId,
        coordinator: coordinator,
        timePort: timePort,
        messagePort: messagePort,
      );
      originalPorts[name] = messagePort;
    }

    return TestNetwork._(messageBus, nodes, originalPorts);
  }

  /// Returns the node with the given name.
  TestNode operator [](String name) {
    final node = _nodes[name];
    if (node == null) {
      throw ArgumentError('Unknown node: $name');
    }
    return node;
  }

  /// Returns all node IDs in the network.
  List<NodeId> get nodeIds => _nodes.values.map((n) => n.id).toList();

  /// Returns all node names in the network.
  List<String> get nodeNames => _nodes.keys.toList();

  /// Returns all nodes in the network.
  List<TestNode> get nodes => _nodes.values.toList();

  /// Connects two nodes as peers (bidirectional).
  Future<void> connect(String node1, String node2) async {
    final n1 = this[node1];
    final n2 = this[node2];
    await n1.coordinator.addPeer(n2.id);
    await n2.coordinator.addPeer(n1.id);
  }

  /// Connects all nodes to each other (full mesh).
  Future<void> connectAll() async {
    final names = nodeNames;
    for (var i = 0; i < names.length; i++) {
      for (var j = i + 1; j < names.length; j++) {
        await connect(names[i], names[j]);
      }
    }
  }

  /// Connects nodes in a chain topology: A -- B -- C -- D
  ///
  /// Each node is connected only to its neighbors in the list.
  /// Useful for testing multi-hop propagation.
  ///
  /// Example:
  /// ```dart
  /// await network.connectChain(['a', 'b', 'c']);  // a-b, b-c (no a-c)
  /// ```
  Future<void> connectChain(List<String> orderedNodes) async {
    for (var i = 0; i < orderedNodes.length - 1; i++) {
      await connect(orderedNodes[i], orderedNodes[i + 1]);
    }
  }

  /// Connects nodes in a star topology with a central hub.
  ///
  /// The hub connects to all spokes, but spokes don't connect to each other.
  /// Useful for testing relay through a central node.
  ///
  /// Example:
  /// ```dart
  /// await network.connectStar('hub', ['spoke1', 'spoke2', 'spoke3']);
  /// ```
  Future<void> connectStar(String hub, List<String> spokes) async {
    for (final spoke in spokes) {
      await connect(hub, spoke);
    }
  }

  /// Connects nodes in a ring topology: A -- B -- C -- D -- A
  ///
  /// Each node connects to exactly two neighbors, forming a circle.
  /// Useful for testing propagation in circular networks.
  ///
  /// Example:
  /// ```dart
  /// await network.connectRing(['a', 'b', 'c', 'd']);  // a-b, b-c, c-d, d-a
  /// ```
  Future<void> connectRing(List<String> orderedNodes) async {
    if (orderedNodes.length < 2) return;
    // Connect chain
    await connectChain(orderedNodes);
    // Close the ring
    await connect(orderedNodes.last, orderedNodes.first);
  }

  /// Starts all coordinators in the network.
  Future<void> startAll() async {
    for (final node in _nodes.values) {
      await node.coordinator.start();
    }
  }

  /// Disposes all coordinators in the network.
  Future<void> dispose() async {
    for (final node in _nodes.values) {
      await node.coordinator.dispose();
    }
  }

  /// Triggers gossip/probe rounds on all nodes.
  ///
  /// [rounds] - Number of rounds to trigger.
  /// [advanceMs] - Simulated time to advance per round (default 1000ms).
  ///               This should be >= the probe round interval (1000ms) to
  ///               ensure probe timeouts expire.
  ///
  /// Uses [InMemoryTimePort.advance] to advance simulated time, which:
  /// - Triggers periodic callbacks (gossip/probe rounds)
  /// - Completes any pending delays (probe timeouts)
  ///
  /// This is much faster than real delays since no actual waiting occurs.
  Future<void> runRounds(int rounds, {int advanceMs = 1000}) async {
    for (var i = 0; i < rounds; i++) {
      for (final node in _nodes.values) {
        await node.timePort.advance(Duration(milliseconds: advanceMs));
      }
    }
  }

  /// Partitions a node from the network (simulates network failure).
  ///
  /// The node will not receive any messages until [heal] is called.
  void partition(String nodeName) {
    final node = this[nodeName];
    _messageBus.unregister(node.id);
    _partitionedNodes.add(nodeName);
  }

  /// Partitions multiple nodes from the network.
  ///
  /// Each node will not receive any messages until healed.
  ///
  /// Example:
  /// ```dart
  /// network.partitionNodes(['node2', 'node3']);
  /// ```
  void partitionNodes(List<String> nodeNames) {
    for (final name in nodeNames) {
      partition(name);
    }
  }

  /// Heals a partitioned node, restoring network connectivity.
  ///
  /// Note: This re-registers the original port. The node may need
  /// probe rounds to recover from suspected/unreachable status.
  void heal(String nodeName) {
    final port = _originalPorts[nodeName]!;
    port.reregister();
    _partitionedNodes.remove(nodeName);
  }

  /// Heals multiple partitioned nodes.
  ///
  /// Example:
  /// ```dart
  /// network.healNodes(['node2', 'node3']);
  /// ```
  void healNodes(List<String> nodeNames) {
    for (final name in nodeNames) {
      heal(name);
    }
  }

  /// Heals all partitioned nodes in the network.
  void healAll() {
    for (final name in _partitionedNodes.toList()) {
      heal(name);
    }
  }

  /// Returns true if the node is currently partitioned.
  bool isPartitioned(String nodeName) => _partitionedNodes.contains(nodeName);

  /// Creates a channel with a stream on specified nodes with mutual membership.
  ///
  /// This is a convenience method that:
  /// 1. Creates the channel on each specified node
  /// 2. Creates the stream on each node
  /// 3. Adds all specified nodes as members on each channel
  ///
  /// [channelId] - The channel to create.
  /// [streamId] - The stream to create within the channel.
  /// [members] - Node names to include (defaults to all nodes).
  ///
  /// ## Example
  /// ```dart
  /// // Create channel on all nodes with mutual membership
  /// await network.setupChannel(channelId, streamId);
  ///
  /// // Create channel on specific nodes only
  /// await network.setupChannel(channelId, streamId, members: ['node1', 'node2']);
  /// ```
  Future<void> setupChannel(
    ChannelId channelId,
    StreamId streamId, {
    List<String>? members,
  }) async {
    final memberNames = members ?? nodeNames;
    final memberIds = memberNames.map((n) => this[n].id).toList();

    for (final name in memberNames) {
      final node = this[name];
      await node.createChannel(channelId);
      await node.createStream(channelId, streamId);

      // Add all other members
      for (final memberId in memberIds) {
        if (memberId != node.id) {
          await node.addMember(channelId, memberId);
        }
      }
    }
  }

  /// Adds a node to an existing channel that other nodes already have.
  ///
  /// This handles all the boilerplate for joining a node to a channel:
  /// 1. Creates the channel on the joining node
  /// 2. Creates the stream on the joining node
  /// 3. Adds existing members to the joining node's channel
  /// 4. Adds the joining node to all existing members' channels
  ///
  /// [joiningNode] - The node name that is joining.
  /// [channelId] - The channel to join.
  /// [streamId] - The stream within the channel.
  /// [existingMembers] - Node names that already have the channel.
  ///
  /// Example:
  /// ```dart
  /// // node1 and node2 already have the channel
  /// await network.joinChannel(
  ///   'node3',
  ///   channelId,
  ///   streamId,
  ///   existingMembers: ['node1', 'node2'],
  /// );
  /// ```
  Future<void> joinChannel(
    String joiningNode,
    ChannelId channelId,
    StreamId streamId, {
    required List<String> existingMembers,
  }) async {
    final joining = this[joiningNode];

    // Setup channel on joining node
    await joining.createChannel(channelId);
    await joining.createStream(channelId, streamId);

    // Add existing members to joining node's channel
    for (final memberName in existingMembers) {
      await joining.addMember(channelId, this[memberName].id);
    }

    // Add joining node to existing members' channels
    for (final memberName in existingMembers) {
      final channel = this[memberName].coordinator.getChannel(channelId);
      if (channel != null) {
        await channel.addMember(joining.id);
      }
    }
  }

  /// Checks if all specified nodes have converged on the same entries.
  ///
  /// Returns true if all nodes have the exact same set of entry IDs
  /// (author + sequence), not just the same count.
  Future<bool> hasConverged(
    ChannelId channelId,
    StreamId streamId, {
    List<String>? nodes,
  }) async {
    final checkNodes = nodes ?? nodeNames;
    if (checkNodes.isEmpty) return true;

    // Get entry IDs from first node
    final firstEntries = await this[checkNodes.first].entries(
      channelId,
      streamId,
    );
    final firstIds = firstEntries.map((e) => e.id).toSet();

    // Compare with all other nodes
    for (final name in checkNodes.skip(1)) {
      final entries = await this[name].entries(channelId, streamId);
      final ids = entries.map((e) => e.id).toSet();

      // Check if both sets contain exactly the same IDs
      if (firstIds.length != ids.length) return false;
      if (!firstIds.containsAll(ids)) return false;
    }
    return true;
  }

  /// Gets entry counts for all nodes for a channel/stream.
  ///
  /// Useful for debugging sync issues.
  Future<Map<String, int>> entryCounts(
    ChannelId channelId,
    StreamId streamId, {
    List<String>? nodes,
  }) async {
    final checkNodes = nodes ?? nodeNames;
    final counts = <String, int>{};
    for (final name in checkNodes) {
      counts[name] = await this[name].entryCount(channelId, streamId);
    }
    return counts;
  }
}

/// Extension methods for TestNode to simplify common operations.
extension TestNodeOperations on TestNode {
  /// Starts this node's coordinator.
  Future<void> start() async {
    await coordinator.start();
  }

  /// Returns all peers known to this node.
  List<Peer> get peers => coordinator.peers;

  /// Returns only reachable peers.
  List<Peer> get reachablePeers => coordinator.reachablePeers;

  /// Returns the peer status for a specific node.
  ///
  /// Returns null if the node is not a peer.
  PeerStatus? peerStatus(NodeId peerId) {
    final peer = peers.where((p) => p.id == peerId).firstOrNull;
    return peer?.status;
  }

  /// Creates a channel on this node.
  Future<void> createChannel(ChannelId channelId) async {
    await coordinator.createChannel(channelId);
  }

  /// Gets or creates a stream on a channel.
  Future<void> createStream(ChannelId channelId, StreamId streamId) async {
    final channel = coordinator.getChannel(channelId);
    if (channel == null) {
      throw StateError('Channel $channelId not found on node $id');
    }
    await channel.getOrCreateStream(streamId);
  }

  /// Adds a member to a channel on this node.
  Future<void> addMember(ChannelId channelId, NodeId memberId) async {
    final channel = coordinator.getChannel(channelId);
    if (channel == null) {
      throw StateError('Channel $channelId not found on node $id');
    }
    await channel.addMember(memberId);
  }

  /// Writes an entry to a stream.
  Future<void> write(
    ChannelId channelId,
    StreamId streamId,
    List<int> payload,
  ) async {
    final channel = coordinator.getChannel(channelId);
    if (channel == null) {
      throw StateError('Channel $channelId not found on node $id');
    }
    final stream = await channel.getOrCreateStream(streamId);
    await stream.append(Uint8List.fromList(payload));
  }

  /// Gets the entry count for a stream.
  ///
  /// Note: Creates the stream if it doesn't exist (returns 0 in that case).
  Future<int> entryCount(ChannelId channelId, StreamId streamId) async {
    final channel = coordinator.getChannel(channelId);
    if (channel == null) {
      throw StateError('Channel $channelId not found on node $id');
    }
    final stream = await channel.getOrCreateStream(streamId);
    final entries = await stream.getAll();
    return entries.length;
  }

  /// Gets all entries for a stream.
  ///
  /// Note: Creates the stream if it doesn't exist (returns empty list).
  Future<List<LogEntry>> entries(ChannelId channelId, StreamId streamId) async {
    final channel = coordinator.getChannel(channelId);
    if (channel == null) {
      throw StateError('Channel $channelId not found on node $id');
    }
    final stream = await channel.getOrCreateStream(streamId);
    final results = await stream.getAll();
    return results.cast<LogEntry>();
  }
}
