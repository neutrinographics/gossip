import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart' as gossip;
import 'package:gossip/gossip.dart' hide PeerStatus;
import 'package:gossip_nearby/gossip_nearby.dart';

import '../models/models.dart';
import '../services/services.dart';

/// Connection status for the transport layer.
enum ConnectionStatus { disconnected, advertising, discovering, connected }

/// Main controller for the chat app state.
class ChatController extends ChangeNotifier {
  final ChatService _chatService;
  final ConnectionService _connectionService;
  final Coordinator _coordinator;

  List<ChannelState> _channels = [];
  List<PeerState> _peers = [];
  ChannelId? _currentChannelId;
  List<MessageState> _currentMessages = [];
  Set<NodeId> _typingUsers = {};
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  bool _isTyping = false;

  StreamSubscription<DomainEvent>? _eventSubscription;
  StreamSubscription<PeerEvent>? _peerSubscription;
  Timer? _typingTimer;
  Timer? _typingExpirationTimer;

  ChatController({
    required ChatService chatService,
    required ConnectionService connectionService,
    required Coordinator coordinator,
  }) : _chatService = chatService,
       _connectionService = connectionService,
       _coordinator = coordinator {
    _setupEventHandling();
    _refreshChannels();
  }

  // --- Getters ---

  List<ChannelState> get channels => _channels;
  List<PeerState> get peers => _peers;
  ChannelId? get currentChannelId => _currentChannelId;
  ChannelState? get currentChannel => _currentChannelId != null
      ? _channels.cast<ChannelState?>().firstWhere(
          (c) => c?.id == _currentChannelId,
          orElse: () => null,
        )
      : null;
  List<MessageState> get currentMessages => _currentMessages;
  Set<NodeId> get typingUsers => _typingUsers;
  ConnectionStatus get connectionStatus => _connectionStatus;
  bool get isTyping => _isTyping;
  NodeId get localNodeId => _chatService.localNodeId;

  // --- Event Handling ---

  void _setupEventHandling() {
    _eventSubscription = _coordinator.events.listen(_onDomainEvent);
    _peerSubscription = _connectionService.peerEvents.listen(_onPeerEvent);
  }

  void _onDomainEvent(DomainEvent event) {
    switch (event) {
      case EntryAppended(:final channelId, :final streamId, :final entry):
        _onEntryAppended(channelId, streamId, entry);
      case EntriesMerged(:final channelId, :final streamId, :final entries):
        _onEntriesMerged(channelId, streamId, entries);
      case ChannelCreated():
        _refreshChannels();
      case ChannelRemoved():
        _refreshChannels();
      case PeerStatusChanged(:final peerId, :final newStatus):
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
    ChannelId channelId,
    StreamId streamId,
    LogEntry entry,
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
    }
  }

  void _onEntriesMerged(
    ChannelId channelId,
    StreamId streamId,
    List<LogEntry> entries,
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
    }
  }

  void _updatePeerStatus(NodeId peerId, gossip.PeerStatus newStatus) {
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
          name: metadata?.name ?? channelId.value.substring(0, 8),
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
          ),
        )
        .toList();
    notifyListeners();
  }

  Future<void> _refreshTypingUsers() async {
    if (_currentChannelId == null) {
      _typingUsers = {};
      notifyListeners();
      return;
    }

    final typingMap = await _chatService.getTypingUsers(_currentChannelId!);
    _typingUsers = typingMap.keys.toSet();
    notifyListeners();

    // Schedule expiration check
    _typingExpirationTimer?.cancel();
    _typingExpirationTimer = Timer(const Duration(seconds: 5), () {
      _refreshTypingUsers();
    });
  }

  void _refreshPeers() {
    final coordinatorPeers = _connectionService.peers;
    _peers = coordinatorPeers
        .map(
          (p) => PeerState(
            id: p.id,
            displayName: p.id.value.substring(0, 8),
            status: _mapPeerStatus(p.status),
          ),
        )
        .toList();
    notifyListeners();
  }

  // --- Actions ---

  Future<void> createChannel(String name) async {
    await _chatService.createChannel(name);
    await _refreshChannels();
  }

  Future<void> joinChannel(String channelIdValue) async {
    final channelId = ChannelId(channelIdValue);
    await _chatService.joinChannel(channelId);
    await _refreshChannels();
  }

  Future<void> leaveChannel(ChannelId channelId) async {
    if (_currentChannelId == channelId) {
      _currentChannelId = null;
      _currentMessages = [];
      _typingUsers = {};
    }
    await _chatService.leaveChannel(channelId);
    await _refreshChannels();
  }

  Future<void> selectChannel(ChannelId channelId) async {
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
    await _chatService.sendMessage(_currentChannelId!, text.trim());
    _isTyping = false;
    _typingTimer?.cancel();
  }

  Future<void> setTyping(bool isTyping) async {
    if (_currentChannelId == null) return;
    if (_isTyping == isTyping) return;

    _isTyping = isTyping;
    await _chatService.setTyping(_currentChannelId!, isTyping);

    // Auto-clear typing after 5 seconds of no input
    _typingTimer?.cancel();
    if (isTyping) {
      _typingTimer = Timer(const Duration(seconds: 5), () {
        setTyping(false);
      });
    }
  }

  Future<void> startNetworking() async {
    await _connectionService.startAdvertising();
    await _connectionService.startDiscovery();
    _updateConnectionStatus();
  }

  Future<void> stopNetworking() async {
    await _connectionService.stopDiscovery();
    await _connectionService.stopAdvertising();
    _updateConnectionStatus();
  }

  String getTypingIndicatorText() {
    if (_typingUsers.isEmpty) return '';

    final names = _typingUsers.map((id) {
      final peer = _peers.cast<PeerState?>().firstWhere(
        (p) => p?.id == id,
        orElse: () => null,
      );
      return peer?.displayName ?? id.value.substring(0, 8);
    }).toList();

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
    super.dispose();
  }
}
