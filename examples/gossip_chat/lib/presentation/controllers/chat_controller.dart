import 'dart:async';

import 'package:bluey/bluey.dart' as bluey;
import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart' as gossip;
import 'package:gossip_bluey/gossip_bluey.dart';

import '../../application/services/services.dart';
import '../../domain/entities/entities.dart';
import '../../infrastructure/services/permission_service.dart';
import '../managers/signal_strength_manager.dart';
import '../view_models/view_models.dart';

/// Connection status for the transport layer.
///
/// Composes bluey's [bluey.AdvertisingState] and [bluey.ScanState] into a
/// single status used by the UI. Ordering of branches in
/// [ChatController._updateConnectionStatus] determines precedence:
/// bluetoothOff > invalidated > connected > meshActive > advertising/scan
/// transients.
enum ConnectionStatus {
  /// Bluetooth adapter is off / unauthorized / unsupported / unknown.
  /// Takes precedence over every other status because the radio cannot
  /// be used at all.
  bluetoothOff,
  disconnected,

  // Transient advertising / scanning lifecycle (sourced from
  // bluey.AdvertisingState / bluey.ScanState).
  advertisingStarting,
  advertising,
  advertisingStopping,
  discoveryStarting,
  discovering,
  discoveryStopping,

  // Composed: both advertising AND scanning active.
  meshActive,

  // Terminal recovery state: an adapter cycle invalidated the live
  // server/scanner. The user must restart networking.
  invalidated,

  connected,
}

/// Callback for controller errors (e.g., networking failures).
typedef ControllerErrorCallback = void Function(String operation, Object error);

/// Merges a [ScanCandidate] into the peer map, keyed by NodeId when known
/// or BleAddress pre-handshake. Pure function; testable in isolation.
///
/// If an entry already exists for [c.address] (matched by `peer.address`),
/// it is updated in-place with the new rssi/lastSeen/displayName, preserving
/// nodeId/everConnected/status. If no entry exists, a new
/// [DiscoveredPeerStatus.discovered] entry is inserted under the BleAddress
/// key.
@visibleForTesting
void mergeCandidate(Map<Object, DiscoveredPeer> peers, ScanCandidate c) {
  // Find existing entry by address (may be keyed by either BleAddress or NodeId).
  DiscoveredPeer? existing;
  for (final p in peers.values) {
    if (p.address == c.address) {
      existing = p;
      break;
    }
  }
  if (existing != null) {
    final key = existing.nodeId ?? existing.address;
    peers[key] = existing.copyWith(
      rssi: c.rssi,
      lastSeenAt: c.lastSeen,
      displayName: c.displayName ?? existing.displayName,
    );
    return;
  }
  peers[c.address] = DiscoveredPeer(
    address: c.address,
    displayName: c.displayName,
    rssi: c.rssi,
    lastSeenAt: c.lastSeen,
    status: DiscoveredPeerStatus.discovered,
  );
}

/// Merges a PeerOpened (transport-level peer connected) event into the peer
/// map. Used by the auto-mode / event-driven path; the user-initiated
/// [ChatController.tapPeer] path handles its own rekey synchronously off
/// the [ConnectionService.connectTo] return value, so it does NOT rely on
/// this helper for rekeying.
///
/// If an entry exists keyed by [nodeId], it is updated in place. Otherwise
/// we fall back to "first entry with status connecting and no nodeId yet"
/// and rekey it. If nothing matches, a fresh NodeId-keyed entry is inserted.
@visibleForTesting
void mergePeerOpened(
  Map<Object, DiscoveredPeer> peers,
  gossip.NodeId nodeId, {
  String? displayName,
  DateTime? now,
}) {
  final timestamp = now ?? DateTime.now();
  // Already keyed by NodeId?
  final existingByNode = peers[nodeId];
  if (existingByNode != null) {
    peers[nodeId] = existingByNode.copyWith(
      status: DiscoveredPeerStatus.connected,
      everConnected: true,
      displayName: displayName ?? existingByNode.displayName,
      lastSeenAt: timestamp,
    );
    return;
  }
  // Fallback: a single in-flight connecting entry without a known nodeId.
  Object? oldKey;
  DiscoveredPeer? toRekey;
  for (final entry in peers.entries) {
    final p = entry.value;
    if (p.nodeId == null &&
        p.status == DiscoveredPeerStatus.connecting) {
      oldKey = entry.key;
      toRekey = p;
      break;
    }
  }
  if (toRekey != null && oldKey != null) {
    peers.remove(oldKey);
    peers[nodeId] = toRekey.copyWith(
      nodeId: nodeId,
      status: DiscoveredPeerStatus.connected,
      everConnected: true,
      displayName: displayName ?? toRekey.displayName,
      lastSeenAt: timestamp,
    );
    return;
  }
  // Brand-new entry (direct connection without a prior scan emission).
  // BleAddress is unknown here; use a synthetic placeholder derived from
  // the NodeId so DiscoveredPeer's required `address` field is satisfied.
  // The UI keys off NodeId in this case anyway.
  peers[nodeId] = DiscoveredPeer(
    address: BleAddress(nodeId.value),
    nodeId: nodeId,
    displayName: displayName,
    lastSeenAt: timestamp,
    status: DiscoveredPeerStatus.connected,
    everConnected: true,
  );
}

/// Merges a PeerClosed (transport-level peer disconnected) event into the
/// peer map. Sets status to [DiscoveredPeerStatus.unreachable] and keeps
/// the entry; the `everConnected: true` flag (set on the prior PeerOpened)
/// prevents prune-on-stop from evicting it.
@visibleForTesting
void mergePeerClosed(Map<Object, DiscoveredPeer> peers, gossip.NodeId nodeId) {
  final existing = peers[nodeId];
  if (existing == null) return;
  peers[nodeId] = existing.copyWith(
    status: DiscoveredPeerStatus.unreachable,
  );
}

/// Maps a gossip [gossip.PeerStatus] update to the corresponding
/// [DiscoveredPeerStatus] for the peer keyed by [nodeId]. No-op if the
/// peer is not currently in the map — a gossip-only status update for a
/// not-yet-connected peer is informational and must not surprise the user
/// with a "connected" pill on a discovered-but-not-yet-connected row.
@visibleForTesting
void mergeGossipPeerStatus(
  Map<Object, DiscoveredPeer> peers,
  gossip.NodeId nodeId,
  gossip.PeerStatus status,
) {
  final existing = peers[nodeId];
  if (existing == null) return;
  final mapped = switch (status) {
    gossip.PeerStatus.reachable => DiscoveredPeerStatus.connected,
    gossip.PeerStatus.suspected => DiscoveredPeerStatus.suspected,
    gossip.PeerStatus.unreachable => DiscoveredPeerStatus.unreachable,
  };
  peers[nodeId] = existing.copyWith(status: mapped);
}

/// Prune-on-stop: drop every peer that has never reached `connected`
/// (i.e. `everConnected == false`). Peers that were once connected stay
/// regardless of current status. Pure function; testable in isolation.
@visibleForTesting
void pruneUnconnected(Map<Object, DiscoveredPeer> peers) {
  peers.removeWhere((_, peer) => !peer.everConnected);
}

/// Composes the displayed ConnectionStatus from its inputs.
///
/// Precedence (highest to lowest):
///   1. bluetoothOff       — radio unusable.
///   2. invalidated        — adapter cycle invalidated the live server/scanner.
///   3. connected          — at least one peer in the registry.
///   4. meshActive         — both advertising AND scanning are active.
///   5. adv/scan transients — starting/advertising/stopping or
///                            starting/scanning/stopping.
///   6. disconnected       — none of the above.
///
/// Pure function; testable in isolation.
@visibleForTesting
ConnectionStatus computeConnectionStatus({
  required BluetoothAdapterState bluetoothState,
  required bluey.AdvertisingState advertisingState,
  required bluey.ScanState scanState,
  required int connectedPeerCount,
}) {
  if (bluetoothState != BluetoothAdapterState.on) {
    return ConnectionStatus.bluetoothOff;
  }
  if (advertisingState == bluey.AdvertisingState.invalidated ||
      scanState == bluey.ScanState.invalidated) {
    return ConnectionStatus.invalidated;
  }
  if (connectedPeerCount > 0) return ConnectionStatus.connected;
  if (advertisingState == bluey.AdvertisingState.advertising &&
      scanState == bluey.ScanState.scanning) {
    return ConnectionStatus.meshActive;
  }
  if (advertisingState == bluey.AdvertisingState.starting) {
    return ConnectionStatus.advertisingStarting;
  }
  if (advertisingState == bluey.AdvertisingState.advertising) {
    return ConnectionStatus.advertising;
  }
  if (advertisingState == bluey.AdvertisingState.stopping) {
    return ConnectionStatus.advertisingStopping;
  }
  if (scanState == bluey.ScanState.starting) {
    return ConnectionStatus.discoveryStarting;
  }
  if (scanState == bluey.ScanState.scanning) {
    return ConnectionStatus.discovering;
  }
  if (scanState == bluey.ScanState.stopping) {
    return ConnectionStatus.discoveryStopping;
  }
  return ConnectionStatus.disconnected;
}

/// Main controller for the chat app state.
///
/// This is a presentation layer controller that manages UI state and
/// delegates all business logic to application services.
class ChatController extends ChangeNotifier {
  /// How often to poll and decay signal strength penalties.
  static const Duration _signalUpdateInterval = Duration(seconds: 2);

  /// How long before typing indicator auto-clears.
  static const Duration _typingTimeout = Duration(seconds: 5);

  /// Prefix length for displaying NodeId as a short identifier.
  static const int _nodeIdPrefixLength = 8;

  /// How often to poll metrics.
  static const Duration _metricsUpdateInterval = Duration(seconds: 2);

  final ChatService _chatService;
  final ConnectionService _connectionService;
  final SyncService _syncService;
  final MetricsService _metricsService;
  final PermissionService _permissionService = PermissionService();
  final ControllerErrorCallback? _onError;

  List<ChannelState> _channels = [];

  /// Merged peer map keyed by either [NodeId] (once known) or
  /// [BleAddress] (pre-handshake). Populated from three sources:
  ///   1. transport candidate events (scan emissions)
  ///   2. transport peer events (PeerOpened/PeerClosed)
  ///   3. gossip [gossip.PeerStatus] updates (SWIM probes)
  final Map<Object, DiscoveredPeer> _peers = {};

  gossip.ChannelId? _currentChannelId;
  List<MessageState> _currentMessages = [];
  Map<gossip.NodeId, TypingEvent> _typingUsers = {};
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  BluetoothAdapterState _bluetoothState = BluetoothAdapterState.unknown;
  bluey.AdvertisingState _advertisingState = bluey.AdvertisingState.idle;
  bluey.ScanState _scanState = bluey.ScanState.stopped;
  bool _isTyping = false;

  /// Tracks delivery status for locally sent messages.
  /// Key: message ID, Value: delivery status
  final Map<String, MessageDeliveryStatus> _messageDeliveryStatus = {};

  /// Manages signal strength smoothing with decay-based penalties.
  final SignalStrengthManager _signalStrengthManager = SignalStrengthManager();

  /// Current metrics state for display.
  MetricsState _metrics = MetricsState.empty();

  /// Tracks indirect peers discovered via version vectors.
  final IndirectPeerService _indirectPeerService;

  /// Cached indirect peers for UI.
  List<IndirectPeerState> _indirectPeers = [];

  StreamSubscription<gossip.DomainEvent>? _eventSubscription;
  StreamSubscription<PeerEvent>? _peerSubscription;
  StreamSubscription<ScanCandidate>? _candidateSubscription;
  StreamSubscription<BluetoothAdapterState>? _bluetoothStateSubscription;
  StreamSubscription<bluey.AdvertisingState>? _advertisingStateSubscription;
  StreamSubscription<bluey.ScanState>? _scanStateSubscription;
  Timer? _typingTimer;
  Timer? _typingExpirationTimer;
  Timer? _signalDecayTimer;
  Timer? _metricsTimer;

  ChatController({
    required ChatService chatService,
    required ConnectionService connectionService,
    required SyncService syncService,
    required MetricsService metricsService,
    ControllerErrorCallback? onError,
  }) : _chatService = chatService,
       _connectionService = connectionService,
       _syncService = syncService,
       _metricsService = metricsService,
       _indirectPeerService = IndirectPeerService(
         localNodeId: chatService.localNodeId,
       ),
       _onError = onError {
    _setupEventHandling();
    _refreshChannels();
  }

  // --- Getters ---

  List<ChannelState> get channels => _channels;
  List<DiscoveredPeer> get peers => List.unmodifiable(_peers.values);
  ConnectionMode get connectionMode => _connectionService.connectionMode;
  gossip.ChannelId? get currentChannelId => _currentChannelId;
  ChannelState? get currentChannel => _currentChannelId != null
      ? _channels.cast<ChannelState?>().firstWhere(
          (c) => c?.id == _currentChannelId,
          orElse: () => null,
        )
      : null;
  List<MessageState> get currentMessages => _currentMessages;
  Set<gossip.NodeId> get typingUsers => _typingUsers.keys.toSet();

  /// Gets the display name for a typing user by NodeId.
  String? getTypingUserName(gossip.NodeId nodeId) {
    return _typingUsers[nodeId]?.senderName;
  }

  ConnectionStatus get connectionStatus => _connectionStatus;
  BluetoothAdapterState get bluetoothAdapterState => _bluetoothState;
  bluey.AdvertisingState get advertisingState => _advertisingState;
  bluey.ScanState get scanState => _scanState;
  bool get isTyping => _isTyping;
  gossip.NodeId get localNodeId => _chatService.localNodeId;
  MetricsState get metrics => _metrics;
  List<IndirectPeerState> get indirectPeers => _indirectPeers;

  // --- Event Handling ---

  void _setupEventHandling() {
    // Subscribe to domain events via SyncService (not Coordinator directly)
    _eventSubscription = _syncService.events.listen(_onDomainEvent);
    _peerSubscription = _connectionService.peerEvents.listen(_onPeerEvent);
    _candidateSubscription = _connectionService.candidateEvents.listen(
      _onCandidate,
    );
    _bluetoothStateSubscription = _connectionService.bluetoothStateStream
        .listen(_onBluetoothStateChanged);
    // `_advertisingState` / `_scanState` defaults (idle / stopped) match
    // bluey's initial values, so the first replay tick lands cleanly.
    _advertisingStateSubscription = _connectionService.advertisingStateStream
        .listen(_onAdvertisingStateChanged);
    _scanStateSubscription = _connectionService.scanStateStream
        .listen(_onScanStateChanged);

    // Start signal update timer - refreshes peer signal strength periodically.
    // This polls failedProbeCount from the gossip library and decays penalties.
    _signalDecayTimer = Timer.periodic(_signalUpdateInterval, (_) {
      _refreshPeerSignalStrength();
    });

    // Start metrics polling timer
    _metricsTimer = Timer.periodic(_metricsUpdateInterval, (_) {
      _refreshMetrics();
    });
  }

  Future<void> _refreshMetrics() async {
    _metricsService.sampleRates();
    _metrics = await _metricsService.getMetrics();
    notifyListeners();
  }

  void _onDomainEvent(gossip.DomainEvent event) {
    switch (event) {
      case gossip.EntryAppended(
        :final channelId,
        :final streamId,
        :final entry,
      ):
        _onEntryAppended(channelId, streamId, entry);
      case gossip.EntriesMerged(
        :final channelId,
        :final streamId,
        :final entries,
        :final newVersion,
      ):
        _onEntriesMerged(channelId, streamId, entries, newVersion);
      case gossip.ChannelCreated():
        _refreshChannels();
      case gossip.ChannelRemoved():
        _refreshChannels();
      case gossip.PeerStatusChanged(:final peerId, :final newStatus):
        _updatePeerStatus(peerId, newStatus);
      default:
        break;
    }
  }

  void _onPeerEvent(PeerEvent event) {
    switch (event) {
      case PeerConnected(:final nodeId, :final displayName):
        mergePeerOpened(_peers, nodeId, displayName: displayName);
        _signalStrengthManager.updatePenalty(nodeId, 0);
        _refreshIndirectPeers();
        _updateConnectionStatus();
        notifyListeners();
      case PeerDisconnected(:final nodeId):
        mergePeerClosed(_peers, nodeId);
        _signalStrengthManager.clearPeer(nodeId);
        _refreshIndirectPeers();
        _updateConnectionStatus();
        notifyListeners();
    }
  }

  void _onCandidate(ScanCandidate c) {
    mergeCandidate(_peers, c);
    notifyListeners();
  }

  void _onEntryAppended(
    gossip.ChannelId channelId,
    gossip.StreamId streamId,
    gossip.LogEntry entry,
  ) {
    if (streamId == StreamIds.messages) {
      _refreshChannels();
      if (channelId == _currentChannelId) {
        _refreshCurrentMessages();
      }
    } else if (streamId == StreamIds.presence) {
      if (channelId == _currentChannelId) {
        _refreshTypingUsers();
      }
    } else if (streamId == StreamIds.metadata) {
      _refreshChannels();
    }
  }

  void _onEntriesMerged(
    gossip.ChannelId channelId,
    gossip.StreamId streamId,
    List<gossip.LogEntry> entries,
    gossip.VersionVector newVersion,
  ) {
    // Track authors from version vector to discover indirect peers
    _indirectPeerService.onEntriesMerged(newVersion, entries);
    _refreshIndirectPeers();

    if (streamId == StreamIds.messages) {
      _refreshChannels();
      if (channelId == _currentChannelId) {
        _refreshCurrentMessages();
      }
    } else if (streamId == StreamIds.presence) {
      if (channelId == _currentChannelId) {
        _refreshTypingUsers();
      }
    } else if (streamId == StreamIds.metadata) {
      _refreshChannels();
    }
  }

  void _updatePeerStatus(gossip.NodeId peerId, gossip.PeerStatus newStatus) {
    final before = _peers[peerId];
    mergeGossipPeerStatus(_peers, peerId, newStatus);
    if (!identical(before, _peers[peerId])) {
      notifyListeners();
    }
  }

  void _updateConnectionStatus() {
    final old = _connectionStatus;
    _connectionStatus = computeConnectionStatus(
      bluetoothState: _bluetoothState,
      advertisingState: _advertisingState,
      scanState: _scanState,
      connectedPeerCount: _connectionService.connectedPeerCount,
    );
    if (old != _connectionStatus) notifyListeners();
  }

  void _onBluetoothStateChanged(BluetoothAdapterState state) {
    _bluetoothState = state;
    _updateConnectionStatus();
    notifyListeners();
  }

  void _onAdvertisingStateChanged(bluey.AdvertisingState state) {
    _advertisingState = state;
    _updateConnectionStatus();
  }

  void _onScanStateChanged(bluey.ScanState state) {
    _scanState = state;
    _updateConnectionStatus();
    if (state != bluey.ScanState.scanning) {
      final before = _peers.length;
      pruneUnconnected(_peers);
      if (_peers.length != before) notifyListeners();
    }
  }

  // --- Refresh Methods ---

  Future<void> _refreshChannels() async {
    final channelIds = _chatService.channelIds;
    final newChannels = <ChannelState>[];

    for (final channelId in channelIds) {
      final metadata = await _chatService.getChannelMetadata(channelId);
      final messages = await _chatService.getMessages(channelId);

      final lastMessage = messages.isNotEmpty ? messages.last : null;

      newChannels.add(
        ChannelState(
          id: channelId,
          name:
              metadata?.name ??
              channelId.value.substring(0, _nodeIdPrefixLength),
          unreadCount: 0,
          lastMessage: lastMessage?.text,
          lastMessageAt: lastMessage?.sentAt,
        ),
      );
    }

    // Sort by last message time
    newChannels.sort((a, b) {
      if (a.lastMessageAt == null && b.lastMessageAt == null) return 0;
      if (a.lastMessageAt == null) return 1;
      if (b.lastMessageAt == null) return -1;
      return b.lastMessageAt!.compareTo(a.lastMessageAt!);
    });

    _channels = newChannels;
    notifyListeners();
  }

  Future<void> _refreshCurrentMessages() async {
    if (_currentChannelId == null) {
      _currentMessages = [];
      notifyListeners();
      return;
    }

    final messages = await _chatService.getMessages(_currentChannelId!);
    _currentMessages = messages
        .map(
          (m) => MessageState(
            id: m.id,
            text: m.text,
            senderName: m.senderName,
            senderNode: m.senderNode,
            sentAt: m.sentAt,
            isLocal: m.senderNode == localNodeId,
            deliveryStatus: _getDeliveryStatus(
              m.id,
              m.senderNode == localNodeId,
            ),
          ),
        )
        .toList();
    notifyListeners();
  }

  /// Gets the delivery status for a message.
  ///
  /// For local messages, checks the tracked status.
  /// For remote messages, always returns [MessageDeliveryStatus.sent].
  MessageDeliveryStatus _getDeliveryStatus(String messageId, bool isLocal) {
    if (!isLocal) {
      return MessageDeliveryStatus.sent;
    }
    // If message exists in storage, it was successfully sent
    // Only messages in _messageDeliveryStatus with non-sent status need special handling
    return _messageDeliveryStatus[messageId] ?? MessageDeliveryStatus.sent;
  }

  Future<void> _refreshTypingUsers() async {
    if (_currentChannelId == null) {
      _typingUsers = {};
      notifyListeners();
      return;
    }

    _typingUsers = await _chatService.getTypingUsers(_currentChannelId!);
    notifyListeners();

    // Schedule expiration check
    _typingExpirationTimer?.cancel();
    _typingExpirationTimer = Timer(_typingTimeout, () {
      _refreshTypingUsers();
    });
  }

  void _refreshIndirectPeers() {
    final directPeerIds = <gossip.NodeId>{};
    for (final p in _peers.values) {
      final id = p.nodeId;
      if (id != null) directPeerIds.add(id);
    }
    final indirectNodeIds = _indirectPeerService.getIndirectPeers(
      directPeerIds: directPeerIds,
    );

    _indirectPeers = indirectNodeIds.map((nodeId) {
      return IndirectPeerState(
        id: nodeId,
        displayName: nodeId.value.substring(0, _nodeIdPrefixLength),
        lastSeenAt: _indirectPeerService.getLastSeenAt(nodeId),
        activityStatus: _indirectPeerService.getActivityStatus(nodeId),
      );
    }).toList();

    // Sort by activity status (most active first)
    _indirectPeers.sort((a, b) {
      return a.activityStatus.index.compareTo(b.activityStatus.index);
    });
  }

  /// Returns smoothed failed-probe count for a peer (0-2). Used by the
  /// peers screen for the gossip-health signal indicator.
  int getSmoothedFailedProbeCount(gossip.NodeId nodeId) =>
      _signalStrengthManager.getSmoothedFailedProbeCount(nodeId);

  /// Refreshes peer signal strength by polling latest probe counts and
  /// decaying penalties. Polls gossip's failedProbeCount for every NodeId
  /// currently in the peer map.
  void _refreshPeerSignalStrength() {
    if (_peers.isEmpty) return;

    // Poll latest failedProbeCount from gossip library for any peers
    // that are known by NodeId (i.e. have completed the handshake).
    final connectedIds = <gossip.NodeId>{};
    for (final p in _peers.values) {
      final id = p.nodeId;
      if (id != null) connectedIds.add(id);
    }
    if (connectedIds.isNotEmpty) {
      final syncPeers = _syncService.peers;
      for (final p in syncPeers) {
        if (connectedIds.contains(p.id)) {
          _signalStrengthManager.updatePenalty(p.id, p.failedProbeCount);
        }
      }
    }

    // Decay penalties and notify if any visible signal level changed.
    if (_signalStrengthManager.decayPenalties()) {
      notifyListeners();
    }
  }

  // --- Actions ---

  Future<void> createChannel(String name) async {
    await _chatService.createChannel(name);
    await _refreshChannels();
  }

  Future<void> joinChannel(String channelIdValue) async {
    final channelId = gossip.ChannelId(channelIdValue);
    await _chatService.joinChannel(channelId);
    await _refreshChannels();
  }

  Future<void> leaveChannel(gossip.ChannelId channelId) async {
    if (_currentChannelId == channelId) {
      _currentChannelId = null;
      _currentMessages = [];
      _typingUsers = {};
    }
    await _chatService.leaveChannel(channelId);
    await _refreshChannels();
  }

  Future<void> selectChannel(gossip.ChannelId channelId) async {
    _currentChannelId = channelId;
    await _refreshCurrentMessages();
    await _refreshTypingUsers();
  }

  void clearCurrentChannel() {
    _currentChannelId = null;
    _currentMessages = [];
    _typingUsers = {};
    _isTyping = false;
    _typingTimer?.cancel();
    notifyListeners();
  }

  Future<void> sendMessage(String text) async {
    if (_currentChannelId == null || text.trim().isEmpty) return;

    final trimmedText = text.trim();
    final messageId = _generateMessageId();

    // Add optimistic message with "sending" status
    final optimisticMessage = MessageState(
      id: messageId,
      text: trimmedText,
      senderName: '', // Will be filled by actual message
      senderNode: localNodeId,
      sentAt: DateTime.now(),
      isLocal: true,
      deliveryStatus: MessageDeliveryStatus.sending,
    );

    _messageDeliveryStatus[messageId] = MessageDeliveryStatus.sending;
    _currentMessages = [..._currentMessages, optimisticMessage];
    notifyListeners();

    // Clear typing state (presentation concern)
    if (_isTyping) {
      _isTyping = false;
      _typingTimer?.cancel();
      // Don't await - fire and forget
      _chatService.setTyping(_currentChannelId!, false);
    }

    try {
      await _chatService.sendMessage(
        _currentChannelId!,
        trimmedText,
        messageId: messageId,
      );
      _messageDeliveryStatus[messageId] = MessageDeliveryStatus.sent;
      // Refresh to get the actual message from storage
      await _refreshCurrentMessages();
    } catch (e) {
      _messageDeliveryStatus[messageId] = MessageDeliveryStatus.failed;
      // Update the optimistic message to show failed status
      final index = _currentMessages.indexWhere((m) => m.id == messageId);
      if (index >= 0) {
        _currentMessages[index] = _currentMessages[index].copyWith(
          deliveryStatus: MessageDeliveryStatus.failed,
        );
        notifyListeners();
      }
    }
  }

  /// Retries sending a failed message.
  Future<void> retryMessage(String messageId) async {
    if (_currentChannelId == null) return;

    final index = _currentMessages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;

    final message = _currentMessages[index];
    if (message.deliveryStatus != MessageDeliveryStatus.failed) return;

    // Update to sending status
    _messageDeliveryStatus[messageId] = MessageDeliveryStatus.sending;
    _currentMessages[index] = message.copyWith(
      deliveryStatus: MessageDeliveryStatus.sending,
    );
    notifyListeners();

    try {
      await _chatService.sendMessage(
        _currentChannelId!,
        message.text,
        messageId: messageId,
      );
      _messageDeliveryStatus[messageId] = MessageDeliveryStatus.sent;
      await _refreshCurrentMessages();
    } catch (e) {
      _messageDeliveryStatus[messageId] = MessageDeliveryStatus.failed;
      _currentMessages[index] = _currentMessages[index].copyWith(
        deliveryStatus: MessageDeliveryStatus.failed,
      );
      notifyListeners();
    }
  }

  String _generateMessageId() {
    return '${DateTime.now().microsecondsSinceEpoch}-${localNodeId.value.substring(0, _nodeIdPrefixLength)}';
  }

  Future<void> setTyping(bool isTyping) async {
    if (_currentChannelId == null) return;
    if (_isTyping == isTyping) return;

    _isTyping = isTyping;
    await _chatService.setTyping(_currentChannelId!, isTyping);

    // Auto-clear typing after timeout period of no input
    _typingTimer?.cancel();
    if (isTyping) {
      _typingTimer = Timer(_typingTimeout, () {
        setTyping(false);
      });
    }
  }

  Future<bool> startNetworking() async {
    // Request OS-level permissions first.
    final hasPermissions = await _permissionService
        .requestBluetoothPermissions();
    if (!hasPermissions) {
      return false;
    }

    // Verify BT is on / supported / authorized at the OS layer. Routed
    // through the transport so the app doesn't end up holding a second
    // Bluey instance — having two observably breaks discovery on iOS
    // (duplicate platform listeners on shared CoreBluetooth managers).
    try {
      await _connectionService.ensureReady();
    } catch (e) {
      _onError?.call('startNetworking.ensureReady', e);
      return false;
    }

    try {
      await _connectionService.startAdvertising();
      await _connectionService.startDiscovery();
      _updateConnectionStatus();
      return true;
    } catch (e) {
      _onError?.call('startNetworking', e);
      return false;
    }
  }

  Future<void> stopNetworking() async {
    await _connectionService.stopDiscovery();
    await _connectionService.stopAdvertising();
    await _connectionService.disconnectAll();
    _updateConnectionStatus();
  }

  // --- Manual-mode API ---

  /// Sets the auto-connect policy mode (manual/auto). In manual mode, the
  /// user must tap discovered rows; in auto mode, gossip_bluey's
  /// AutoConnectPolicy initiates connections as candidates appear.
  void setConnectionMode(ConnectionMode mode) {
    _connectionService.setConnectionMode(mode);
    notifyListeners();
  }

  /// Alias for [setConnectionMode]; matches the topology controls API
  /// surface used by the peers screen.
  void setMode(ConnectionMode mode) => setConnectionMode(mode);

  /// Starts or stops BLE advertising independently of discovery.
  Future<void> setAdvertising(bool on) async {
    try {
      if (on) {
        await _connectionService.startAdvertising();
      } else {
        await _connectionService.stopAdvertising();
      }
    } catch (e) {
      _onError?.call(on ? 'startAdvertising' : 'stopAdvertising', e);
    }
  }

  /// Starts or stops BLE discovery independently of advertising.
  Future<void> setDiscovering(bool on) async {
    try {
      if (on) {
        await _connectionService.startDiscovery();
      } else {
        await _connectionService.stopDiscovery();
      }
    } catch (e) {
      _onError?.call(on ? 'startDiscovery' : 'stopDiscovery', e);
    }
  }

  /// Tap-handler for a discovered peer row. For a [discovered]/[failed]
  /// row, initiates a connectTo and flips status to [connecting]. For
  /// connected/suspected/unreachable, no-ops (the caller should surface an
  /// action sheet). For transient states (connecting/disconnecting),
  /// no-ops.
  ///
  /// On success, this method rekeys the entry from BleAddress to NodeId
  /// SYNCHRONOUSLY using the value returned by
  /// [ConnectionService.connectTo] — it does NOT rely on the subsequent
  /// PeerOpened event to perform the rekey. This is important under
  /// concurrency: an inbound PeerOpened (peripheral-role accepting a
  /// remote central) can fire while this outbound connectTo is still
  /// in flight, which would otherwise rekey the wrong row if we relied
  /// on a shared hint set.
  Future<void> tapPeer(DiscoveredPeer peer) async {
    switch (peer.status) {
      case DiscoveredPeerStatus.discovered:
      case DiscoveredPeerStatus.failed:
        final key = peer.nodeId ?? peer.address;
        _peers[key] = peer.copyWith(status: DiscoveredPeerStatus.connecting);
        notifyListeners();
        final gossip.NodeId nodeId;
        try {
          nodeId = await _connectionService.connectByAddress(peer.address);
        } on StateError {
          // No candidate currently known for this address (scanner has
          // not emitted one this session, or discovery was stopped).
          _peers[key] = peer.copyWith(status: DiscoveredPeerStatus.failed);
          notifyListeners();
          return;
        } catch (e) {
          // Connect attempt failed for some other reason. Re-read since
          // PeerOpened may have arrived concurrently (unlikely on
          // failure, but be defensive).
          final current = _peers[key];
          if (current != null &&
              current.status == DiscoveredPeerStatus.connecting) {
            _peers[key] = current.copyWith(
              status: DiscoveredPeerStatus.failed,
            );
            notifyListeners();
          }
          _onError?.call('connectTo', e);
          return;
        }
        // Rekey synchronously off connectTo's return value. The PeerOpened
        // event will still arrive; mergePeerOpened is idempotent on an
        // already-keyed-by-NodeId entry, so it's a safe no-op then.
        final existing = _peers.remove(key);
        if (existing != null) {
          _peers[nodeId] = existing.copyWith(
            nodeId: nodeId,
            status: DiscoveredPeerStatus.connected,
            everConnected: true,
          );
          notifyListeners();
        }
      case DiscoveredPeerStatus.connected:
      case DiscoveredPeerStatus.suspected:
      case DiscoveredPeerStatus.unreachable:
        // Caller's responsibility to show an action sheet (e.g. disconnect).
        return;
      case DiscoveredPeerStatus.connecting:
      case DiscoveredPeerStatus.disconnecting:
        // Transient — ignore.
        return;
    }
  }

  /// Disconnects a specific peer. Flips the entry to
  /// [DiscoveredPeerStatus.disconnecting] until PeerClosed arrives.
  ///
  /// Self-heals if PeerClosed never arrives (already-closed peer, race,
  /// etc.): after [ConnectionService.disconnect] returns, if the peer is
  /// no longer reported as a sync peer and the row is still showing
  /// `disconnecting`, we transition it to `unreachable` so the UI doesn't
  /// get stuck. A later PeerClosed event will be a no-op (mergePeerClosed
  /// keeps unreachable rows at unreachable).
  Future<void> disconnectPeer(gossip.NodeId nodeId) async {
    final existing = _peers[nodeId];
    if (existing != null) {
      _peers[nodeId] =
          existing.copyWith(status: DiscoveredPeerStatus.disconnecting);
      notifyListeners();
    }
    try {
      await _connectionService.disconnect(nodeId);
    } catch (e) {
      _onError?.call('disconnect', e);
      return;
    }
    // Defensive: if no PeerClosed has arrived in time and the peer is no
    // longer in the sync registry, transition to unreachable.
    final stillConnected = _syncService.peers.any((p) => p.id == nodeId);
    if (!stillConnected) {
      final current = _peers[nodeId];
      if (current != null &&
          current.status == DiscoveredPeerStatus.disconnecting) {
        _peers[nodeId] =
            current.copyWith(status: DiscoveredPeerStatus.unreachable);
        notifyListeners();
      }
    }
  }

  String getTypingIndicatorText() {
    if (_typingUsers.isEmpty) return '';

    final names = _typingUsers.values.map((e) => e.senderName).toList();

    if (names.length == 1) {
      return '${names[0]} is typing...';
    } else if (names.length == 2) {
      return '${names[0]} and ${names[1]} are typing...';
    } else {
      return '${names.length} people are typing...';
    }
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _peerSubscription?.cancel();
    _candidateSubscription?.cancel();
    _bluetoothStateSubscription?.cancel();
    _advertisingStateSubscription?.cancel();
    _scanStateSubscription?.cancel();
    _typingTimer?.cancel();
    _typingExpirationTimer?.cancel();
    _signalDecayTimer?.cancel();
    _metricsTimer?.cancel();
    _signalStrengthManager.dispose();
    super.dispose();
  }
}
