# Nearby Chat - Demo App Architecture

A minimal peer-to-peer chat application demonstrating gossip and gossip_nearby integration.

## Purpose

This app exists to:

1. **Validate the gossip stack** - Prove that gossip + gossip_nearby work together
2. **Demonstrate the API** - Show how to integrate these packages
3. **Enable manual testing** - Test sync behavior on real devices
4. **Serve as reference** - Example code for future integrations

This is NOT a production app. It prioritizes clarity over features.

---

## Features

### Core Features (MVP)

- Create chat channels
- Join channels via invite (share channel ID)
- Leave channels
- Send text messages within a channel
- Typing indicators (see who is typing)
- Discover nearby peers automatically
- Sync messages when peers connect
- See online/offline status of peers

### Out of Scope

- User authentication
- Message encryption
- Push notifications
- Media attachments
- Message editing/deletion
- Persistent storage (in-memory only for simplicity)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ ChannelList │  │  ChatScreen │  │     PeersScreen     │  │
│  │   Screen    │  │             │  │                     │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
└─────────┼────────────────┼────────────────────┼─────────────┘
          │                │                    │
          ▼                ▼                    ▼
┌─────────────────────────────────────────────────────────────┐
│                    State Management                          │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                    ChatController                    │    │
│  │  - channels: List<ChannelState>                     │    │
│  │  - peers: List<PeerState>                           │    │
│  │  - connectionStatus: ConnectionStatus               │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                    Service Layer                             │
│  ┌──────────────────────┐  ┌────────────────────────────┐   │
│  │    ChatService       │  │    ConnectionService       │   │
│  │  - createChannel()   │  │  - startDiscovery()        │   │
│  │  - sendMessage()     │  │  - stopDiscovery()         │   │
│  │  - getMessages()     │  │  - startAdvertising()      │   │
│  └──────────┬───────────┘  └─────────────┬──────────────┘   │
└─────────────┼────────────────────────────┼──────────────────┘
              │                            │
              ▼                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Gossip Integration                        │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                    Coordinator                        │   │
│  │  - channels, peers, entries                          │   │
│  │  - events stream                                     │   │
│  └──────────────────────────┬───────────────────────────┘   │
│                             │                               │
│  ┌──────────────────────────▼───────────────────────────┐   │
│  │                  NearbyTransport                      │   │
│  │  - messagePort (for Coordinator)                     │   │
│  │  - peerEvents (connect/disconnect)                   │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Layer Responsibilities

### UI Layer

Simple Flutter widgets. No business logic.

| Screen | Purpose |
|--------|---------|
| `ChannelListScreen` | List channels, create new channel, navigate to chat |
| `ChatScreen` | Display messages, send new messages |
| `PeersScreen` | Show connected peers and their status |

### State Management

Single `ChatController` using `ChangeNotifier` (or Riverpod if preferred).

```dart
class ChatController extends ChangeNotifier {
  // State
  List<ChannelState> channels = [];
  List<PeerState> peers = [];
  ConnectionStatus connectionStatus = ConnectionStatus.disconnected;
  Set<NodeId> typingUsers = {};  // Users typing in current channel
  
  // Computed
  ChannelState? get currentChannel => ...;
  List<MessageState> get currentMessages => ...;
  
  // Actions (delegate to services)
  Future<void> createChannel(String name);
  Future<void> joinChannel(ChannelId id);
  Future<void> leaveChannel(ChannelId id);
  Future<void> selectChannel(ChannelId id);
  Future<void> sendMessage(String text);
  Future<void> setTyping(bool isTyping);
  Future<void> startNetworking();
  Future<void> stopNetworking();
}
```

**Why ChangeNotifier?** Simplest option, no dependencies, sufficient for demo.

### Service Layer

Thin wrappers around gossip and gossip_nearby APIs.

```dart
class ChatService {
  final Coordinator _coordinator;
  
  Future<ChannelId> createChannel(String name);
  Future<void> joinChannel(ChannelId id);
  Future<void> leaveChannel(ChannelId id);
  Future<void> sendMessage(ChannelId channel, String text);
  Future<void> setTyping(ChannelId channel, bool isTyping);
  Stream<List<Message>> watchMessages(ChannelId channel);
  Stream<Set<NodeId>> watchTypingUsers(ChannelId channel);
}

class ConnectionService {
  final NearbyTransport _transport;
  final Coordinator _coordinator;
  
  Future<void> startDiscovery();
  Future<void> stopDiscovery();
  Stream<List<PeerInfo>> watchPeers();
}
```

### Gossip Integration

Direct use of `Coordinator` and `NearbyTransport`.

```dart
// Initialization
final transport = NearbyTransport(
  localNodeId: nodeId,
  serviceId: ServiceId('com.example.nearbychat'),
  displayName: deviceName,
);

final coordinator = await Coordinator.create(
  localNode: nodeId,
  channelRepository: InMemoryChannelRepository(),
  peerRepository: InMemoryPeerRepository(),
  entryRepository: InMemoryEntryRepository(),
  messagePort: transport.messagePort,
  timerPort: RealTimePort(),
);

// Wire up peer events
transport.peerEvents.listen((event) {
  switch (event) {
    case PeerConnected(:final nodeId):
      coordinator.addPeer(nodeId);
    case PeerDisconnected(:final nodeId):
      coordinator.removePeer(nodeId);
  }
});
```

---

## Data Model

### Message Format

Messages are stored as gossip entries with JSON payload:

```dart
class ChatMessage {
  final String id;          // UUID
  final String text;        // Message content
  final String senderName;  // Display name
  final DateTime sentAt;    // Local timestamp
  
  Uint8List encode() => utf8.encode(jsonEncode(toJson()));
  static ChatMessage decode(Uint8List bytes) => ...;
}
```

### Channel Structure

Each chat channel maps to a gossip Channel with two streams:

```
Channel: "general"
├── Stream: "messages"
│   ├── Entry 1: {type: "message", text: "Hello", sender: "Alice", ...}
│   ├── Entry 2: {type: "message", text: "Hi!", sender: "Bob", ...}
│   └── Entry 3: {type: "message", text: "How are you?", sender: "Alice", ...}
│
└── Stream: "presence"
    ├── Entry 1: {type: "typing", sender: "Alice", isTyping: true, ...}
    └── Entry 2: {type: "typing", sender: "Alice", isTyping: false, ...}
```

**Why separate streams?**
- Messages are permanent, presence is ephemeral
- Different retention policies (keep all messages, expire presence after 30s)
- Reduces noise when materializing message history

### Typing Indicator Protocol

Typing state is broadcast via the "presence" stream:

```dart
// When user starts typing
await presenceStream.append(TypingEvent(
  senderNode: localNodeId,
  senderName: displayName,
  isTyping: true,
  timestamp: DateTime.now(),
).encode());

// When user stops typing (or sends message)
await presenceStream.append(TypingEvent(
  senderNode: localNodeId,
  senderName: displayName,
  isTyping: false,
  timestamp: DateTime.now(),
).encode());
```

**Client-side handling:**
- Maintain a map of `NodeId → (isTyping, lastUpdate)`
- On receiving typing event, update the map
- Expire entries older than 5 seconds (timer-based cleanup)
- UI shows users where `isTyping == true` and not expired

### Channel Invite Flow

Channels are identified by their `ChannelId`. To invite someone:

1. **Share the channel ID** - Copy from channel info, send via any means (text, QR, verbally)
2. **Recipient joins** - Enter the channel ID in "Join Channel" dialog
3. **Gossip syncs** - Once both devices have the channel, messages sync automatically

```dart
// Creating a channel
final channelId = ChannelId(uuid.v4());  // Random unique ID
await coordinator.createChannel(channelId);

// Joining an existing channel (by ID)
await coordinator.createChannel(channelId);  // Idempotent - creates if not exists

// The channel name is stored in a metadata entry
await metadataStream.append(ChannelMetadata(name: "General Chat").encode());
```

**Note:** There's no access control - anyone with the channel ID can join and see messages. This is intentional for the demo. Production apps would add encryption or authentication.

### State Classes

```dart
class ChannelState {
  final ChannelId id;
  final String name;
  final int unreadCount;
  final DateTime? lastMessageAt;
}

class MessageState {
  final String id;
  final String text;
  final String senderName;
  final NodeId senderNode;
  final DateTime sentAt;
  final bool isLocal;  // Sent by this device
}

class PeerState {
  final NodeId id;
  final String displayName;
  final PeerStatus status;  // connected, suspected, unreachable
}

enum ConnectionStatus {
  disconnected,
  advertising,
  discovering,
  connected,
}
```

---

## Screen Designs

### Channel List Screen

```
┌────────────────────────────┐
│  Nearby Chat          [P]  │  <- [P] = Peers button
├────────────────────────────┤
│  ┌──────────────────────┐  │
│  │ # general        [×] │  │  <- [×] = Leave channel
│  │   Last: Hi everyone! │  │
│  └──────────────────────┘  │
│  ┌──────────────────────┐  │
│  │ # random    (2)  [×] │  │  <- (2) = unread count
│  │   Last: lol          │  │
│  └──────────────────────┘  │
│                            │
│                            │
│               [Join] [+]   │  <- [Join] = Join by ID, [+] = Create
├────────────────────────────┤
│  ● 2 peers connected       │  <- Status bar
└────────────────────────────┘
```

**Actions:**
- Tap channel → Open chat
- Tap [×] → Leave channel (with confirmation)
- Tap [Join] → Dialog to enter channel ID
- Tap [+] → Dialog to create new channel
- Long press channel → Copy channel ID (for sharing)

### Chat Screen

```
┌────────────────────────────┐
│  ← # general          [i]  │  <- [i] = Channel info (copy ID)
├────────────────────────────┤
│                            │
│  ┌──────────────────────┐  │
│  │ Alice            10:30│  │
│  │ Hello everyone!      │  │
│  └──────────────────────┘  │
│                            │
│         ┌───────────────┐  │
│         │ Hi! How's it  │  │
│         │ going?        │  │
│         │      You 10:31│  │
│         └───────────────┘  │
│                            │
│  Alice is typing...        │  <- Typing indicator
├────────────────────────────┤
│  [  Type a message...  ][>]│
└────────────────────────────┘
```

**Typing Indicator Logic:**
- Show when any remote peer's `isTyping` is true
- Multiple typers: "Alice and Bob are typing..."
- 3+ typers: "3 people are typing..."
- Auto-expire after 5 seconds of no update (in case peer disconnects while typing)

### Peers Screen

```
┌────────────────────────────┐
│  ← Nearby Peers            │
├────────────────────────────┤
│                            │
│  ● Alice's iPhone          │  <- Green = connected
│    Connected               │
│                            │
│  ◐ Bob's Pixel             │  <- Yellow = suspected
│    Connection unstable     │
│                            │
│  ○ Charlie's iPad          │  <- Gray = unreachable
│    Disconnected            │
│                            │
├────────────────────────────┤
│  [Start Discovery]         │  <- Toggle button
└────────────────────────────┘
```

---

## File Structure

```
examples/nearby_chat/
├── lib/
│   ├── main.dart
│   ├── app.dart
│   │
│   ├── models/
│   │   ├── chat_message.dart      # Message payload
│   │   ├── typing_event.dart      # Typing indicator payload
│   │   ├── channel_metadata.dart  # Channel name payload
│   │   ├── channel_state.dart     # UI state
│   │   ├── message_state.dart     # UI state
│   │   └── peer_state.dart        # UI state
│   │
│   ├── services/
│   │   ├── chat_service.dart
│   │   └── connection_service.dart
│   │
│   ├── controllers/
│   │   └── chat_controller.dart
│   │
│   └── ui/
│       ├── screens/
│       │   ├── channel_list_screen.dart
│       │   ├── chat_screen.dart
│       │   └── peers_screen.dart
│       │
│       └── widgets/
│           ├── channel_tile.dart
│           ├── message_bubble.dart
│           └── peer_tile.dart
│
├── pubspec.yaml
├── ARCHITECTURE.md
└── README.md
```

---

## Initialization Flow

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. Generate or load device identity
  final nodeId = NodeId(await getOrCreateDeviceId());
  final deviceName = await getDeviceName();
  
  // 2. Create NearbyTransport
  final transport = NearbyTransport(
    localNodeId: nodeId,
    serviceId: ServiceId('com.example.nearbychat'),
    displayName: deviceName,
  );
  
  // 3. Create Coordinator with in-memory storage
  final coordinator = await Coordinator.create(
    localNode: nodeId,
    channelRepository: InMemoryChannelRepository(),
    peerRepository: InMemoryPeerRepository(),
    entryRepository: InMemoryEntryRepository(),
    messagePort: transport.messagePort,
    timerPort: RealTimePort(),
  );
  
  // 4. Create services
  final chatService = ChatService(coordinator);
  final connectionService = ConnectionService(transport, coordinator);
  
  // 5. Create controller
  final controller = ChatController(
    chatService: chatService,
    connectionService: connectionService,
    coordinator: coordinator,
  );
  
  // 6. Start the app
  runApp(ChatApp(controller: controller));
}
```

---

## Event Handling

### Peer Connection Events

```dart
// In ConnectionService
void _setupPeerEventHandling() {
  _transport.peerEvents.listen((event) {
    switch (event) {
      case PeerConnected(:final nodeId):
        _coordinator.addPeer(nodeId);
        _log('Peer connected: $nodeId');
      case PeerDisconnected(:final nodeId):
        _coordinator.removePeer(nodeId);
        _log('Peer disconnected: $nodeId');
    }
  });
}
```

### Message Sync Events

```dart
// In ChatController
void _setupEventHandling() {
  _coordinator.events.listen((event) {
    switch (event) {
      case EntryAppended(:final channelId, :final entry):
        _onLocalMessage(channelId, entry);
      case EntriesMerged(:final channelId, :final entries):
        _onRemoteMessages(channelId, entries);
      case ChannelCreated(:final channelId):
        _refreshChannels();
      case PeerStatusChanged(:final peerId, :final newStatus):
        _updatePeerStatus(peerId, newStatus);
      default:
        break;
    }
  });
}
```

---

## Platform Permissions

### Android (AndroidManifest.xml)

```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />
```

### iOS (Info.plist)

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to find and connect with nearby devices.</string>
<key>NSLocalNetworkUsageDescription</key>
<string>This app uses the local network to communicate with nearby devices.</string>
```

---

## Testing Strategy

### Manual Testing Scenarios

1. **Single device** - Create channels, send messages (no sync)
2. **Two devices, same channel** - Verify message sync
3. **Two devices, different channels** - Verify channel isolation
4. **Connection drop** - Disconnect WiFi, verify reconnection sync
5. **Three+ devices** - Verify multi-peer gossip propagation
6. **Channel invite** - Device A creates channel, shares ID, Device B joins
7. **Leave channel** - Leave a channel, verify it disappears from list
8. **Typing indicators** - Start typing on Device A, verify indicator on Device B
9. **Typing timeout** - Start typing, disconnect, verify indicator expires on peer

### What to Verify

- Messages appear on all devices in correct order
- Peer status updates correctly
- Offline messages sync when reconnected
- No duplicate messages after reconnection
- Typing indicators appear within 1 second
- Typing indicators expire after 5 seconds of no update
- Joining a channel syncs existing message history
- Leaving a channel removes it locally (doesn't affect other peers)

---

## Dependencies

```yaml
dependencies:
  flutter:
    sdk: flutter
  
  # Gossip packages (path dependencies via melos)
  gossip:
    path: ../../packages/gossip
  gossip_nearby:
    path: ../../packages/gossip_nearby
  
  # Utilities
  uuid: ^4.0.0           # Generate message/device IDs
  device_info_plus: ^9.0.0  # Get device name
  
dev_dependencies:
  flutter_test:
    sdk: flutter
```

---

## Future Enhancements (Out of Scope for MVP)

If the demo proves useful, these could be added later:

1. **Persistence** - SQLite repositories for offline storage
2. **Encryption** - End-to-end encryption for messages
3. **Read receipts** - Track which messages each peer has seen
4. **File sharing** - Chunk large payloads across entries
5. **QR code invites** - Scan to join channel instead of typing ID
