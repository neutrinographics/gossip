import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart' as gossip;
import 'package:gossip_nearby/gossip_nearby.dart';

import '../../application/services/services.dart';
import '../../domain/entities/entities.dart';
import '../../infrastructure/services/permission_service.dart';
import '../managers/signal_strength_manager.dart';
import '../view_models/view_models.dart';

/// Connection status for the transport layer.
enum ConnectionStatus { disconnected, advertising, discovering, connected }

/// Callback for controller errors (e.g., networking failures).
typedef ControllerErrorCallback = void Function(String operation, Object error);

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
  final ChatService _chatService;
  final ConnectionService _connectionService;
  final SyncService _syncService;
  final PermissionService _permissionService = PermissionService();
  final ControllerErrorCallback? _onError;

  List<ChannelState> _channels = [];
  List<PeerState> _peers = [];
  gossip.ChannelId? _currentChannelId;
  List<MessageState> _currentMessages = [];
  Map<gossip.NodeId, TypingEvent> _typingUsers = {};
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  bool _isTyping = false;

  /// Tracks delivery status for locally sent messages.
  /// Key: message ID, Value: delivery status
  final Map<String, MessageDeliveryStatus> _messageDeliveryStatus = {};

  /// Manages signal strength smoothing with decay-based penalties.
  final SignalStrengthManager _signalStrengthManager = SignalStrengthManager();

  StreamSubscription<gossip.DomainEvent>? _eventSubscription;
  StreamSubscription<PeerEvent>? _peerSubscription;
  Timer? _typingTimer;
  Timer? _typingExpirationTimer;
  Timer? _signalDecayTimer;

  ChatController({
    required ChatService chatService,
    required ConnectionService connectionService,
    required SyncService syncService,
    ControllerErrorCallback? onError,
  }) : _chatService = chatService,
       _connectionService = connectionService,
       _syncService = syncService,
       _onError = onError {
    _setupEventHandling();
    _refreshChannels();
  }

  // --- Getters ---

  List<ChannelState> get channels => _channels;
  List<PeerState> get peers => _peers;
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
  bool get isTyping => _isTyping;
  gossip.NodeId get localNodeId => _chatService.localNodeId;

  // --- Event Handling ---

  void _setupEventHandling() {
    // Subscribe to domain events via SyncService (not Coordinator directly)
    _eventSubscription = _syncService.events.listen(_onDomainEvent);
    _peerSubscription = _connectionService.peerEvents.listen(_onPeerEvent);

    // Start signal update timer - refreshes peer signal strength periodically.
    // This polls failedProbeCount from the gossip library and decays penalties.
    _signalDecayTimer = Timer.periodic(_signalUpdateInterval, (_) {
      _refreshPeerSignalStrength();
    });
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
      ):
        _onEntriesMerged(channelId, streamId, entries);
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
      case PeerConnected():
        _refreshPeers();
        _updateConnectionStatus();
      case PeerDisconnected():
        _refreshPeers();
        _updateConnectionStatus();
    }
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

  void _updatePeerStatus(gossip.NodeId peerId, gossip.PeerStatus newStatus) {
    final index = _peers.indexWhere((p) => p.id == peerId);
    if (index >= 0) {
      _peers[index] = _peers[index].copyWith(status: _mapPeerStatus(newStatus));
      notifyListeners();
    }
  }

  PeerConnectionStatus _mapPeerStatus(gossip.PeerStatus status) {
    switch (status) {
      case gossip.PeerStatus.reachable:
        return PeerConnectionStatus.connected;
      case gossip.PeerStatus.suspected:
        return PeerConnectionStatus.suspected;
      case gossip.PeerStatus.unreachable:
        return PeerConnectionStatus.unreachable;
    }
  }

  void _updateConnectionStatus() {
    final oldStatus = _connectionStatus;
    if (_connectionService.connectedPeerCount > 0) {
      _connectionStatus = ConnectionStatus.connected;
    } else if (_connectionService.isDiscovering) {
      _connectionStatus = ConnectionStatus.discovering;
    } else if (_connectionService.isAdvertising) {
      _connectionStatus = ConnectionStatus.advertising;
    } else {
      _connectionStatus = ConnectionStatus.disconnected;
    }
    if (oldStatus != _connectionStatus) {
      notifyListeners();
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

  void _refreshPeers() {
    // Get peers via SyncService (not Coordinator directly)
    final syncPeers = _syncService.peers;
    _peers = syncPeers.map((p) {
      _signalStrengthManager.updatePenalty(p.id, p.failedProbeCount);
      return PeerState(
        id: p.id,
        displayName: p.id.value.substring(0, _nodeIdPrefixLength),
        status: _mapPeerStatus(p.status),
        failedProbeCount: _signalStrengthManager.getSmoothedFailedProbeCount(
          p.id,
        ),
      );
    }).toList();
    notifyListeners();
  }

  /// Refreshes peer signal strength by polling latest probe counts and decaying penalties.
  void _refreshPeerSignalStrength() {
    if (_peers.isEmpty) return;

    // Poll latest failedProbeCount from gossip library
    final syncPeers = _syncService.peers;
    for (final p in syncPeers) {
      _signalStrengthManager.updatePenalty(p.id, p.failedProbeCount);
    }

    // Decay penalties and update UI if changed
    if (_signalStrengthManager.decayPenalties()) {
      _peers = _peers
          .map(
            (p) => p.copyWith(
              failedProbeCount: _signalStrengthManager
                  .getSmoothedFailedProbeCount(p.id),
            ),
          )
          .toList();
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
    // Request permissions first
    final hasPermissions = await _permissionService.requestNearbyPermissions();
    if (!hasPermissions) {
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
    _updateConnectionStatus();
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
    _typingTimer?.cancel();
    _typingExpirationTimer?.cancel();
    _signalDecayTimer?.cancel();
    _signalStrengthManager.dispose();
    super.dispose();
  }
}
