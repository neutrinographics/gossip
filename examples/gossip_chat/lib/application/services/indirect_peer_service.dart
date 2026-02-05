import 'package:gossip/gossip.dart';

/// Activity status for an indirect peer based on entry recency.
enum IndirectPeerActivityStatus {
  /// Entry received within last 15 seconds.
  active,

  /// Entry received within last 1 minute.
  recent,

  /// Entry received within last 5 minutes.
  away,

  /// Entry older than 5 minutes.
  stale,

  /// No timestamp data available.
  unknown,
}

/// Service for tracking indirect peers discovered via version vectors.
///
/// An indirect peer is a node that has authored entries we've synced,
/// but to which we don't have a direct connection. We learned about
/// these peers transitively through gossip with direct peers.
///
/// This service listens to [EntriesMerged] events and extracts author
/// information from version vectors to build a picture of the network.
class IndirectPeerService {
  static const Duration _activeThreshold = Duration(seconds: 15);
  static const Duration _recentThreshold = Duration(minutes: 1);
  static const Duration _awayThreshold = Duration(minutes: 5);

  final NodeId _localNodeId;
  final Set<NodeId> _knownAuthors = {};
  final Map<NodeId, DateTime> _lastSeenAt = {};

  IndirectPeerService({required NodeId localNodeId})
    : _localNodeId = localNodeId;

  /// All remote authors we've seen in version vectors.
  ///
  /// This excludes the local node.
  Set<NodeId> get knownAuthors => Set.unmodifiable(_knownAuthors);

  /// Processes an [EntriesMerged] event to extract author information.
  ///
  /// Call this when receiving [EntriesMerged] domain events from the
  /// coordinator's event stream. Pass the entries list to track
  /// last seen timestamps for activity status.
  void onEntriesMerged(VersionVector versionVector, List<LogEntry> entries) {
    for (final nodeId in versionVector.entries.keys) {
      if (nodeId != _localNodeId) {
        _knownAuthors.add(nodeId);
      }
    }

    // Track last seen timestamps from entries
    for (final entry in entries) {
      if (entry.author == _localNodeId) continue;

      final entryTime = DateTime.fromMillisecondsSinceEpoch(
        entry.timestamp.physicalMs,
      );
      final existing = _lastSeenAt[entry.author];

      if (existing == null || entryTime.isAfter(existing)) {
        _lastSeenAt[entry.author] = entryTime;
      }
    }
  }

  /// Returns the set of indirect peers.
  ///
  /// Indirect peers are authors we've seen in version vectors but who
  /// are not in our set of direct peers.
  Set<NodeId> getIndirectPeers({required Set<NodeId> directPeerIds}) {
    return _knownAuthors.difference(directPeerIds);
  }

  /// Returns the last seen timestamp for an author.
  ///
  /// Returns null if the author is unknown or is the local node.
  DateTime? getLastSeenAt(NodeId nodeId) {
    if (nodeId == _localNodeId) return null;
    return _lastSeenAt[nodeId];
  }

  /// Returns the activity status for an author based on entry recency.
  ///
  /// The [now] parameter can be provided for testing; defaults to current time.
  IndirectPeerActivityStatus getActivityStatus(NodeId nodeId, {DateTime? now}) {
    final lastSeen = _lastSeenAt[nodeId];
    if (lastSeen == null) return IndirectPeerActivityStatus.unknown;

    final currentTime = now ?? DateTime.now();
    final elapsed = currentTime.difference(lastSeen);

    if (elapsed <= _activeThreshold) {
      return IndirectPeerActivityStatus.active;
    } else if (elapsed <= _recentThreshold) {
      return IndirectPeerActivityStatus.recent;
    } else if (elapsed <= _awayThreshold) {
      return IndirectPeerActivityStatus.away;
    } else {
      return IndirectPeerActivityStatus.stale;
    }
  }

  /// Clears all tracked authors and timestamps.
  ///
  /// Use when resetting state, e.g., when leaving all channels.
  void clear() {
    _knownAuthors.clear();
    _lastSeenAt.clear();
  }
}
