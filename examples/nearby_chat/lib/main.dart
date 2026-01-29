import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/gossip_nearby.dart';
import 'package:uuid/uuid.dart';

import 'app.dart';
import 'controllers/chat_controller.dart';
import 'services/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Generate or load device identity
  final nodeId = NodeId(const Uuid().v4());
  final deviceName = await _getDeviceName();

  // Create NearbyTransport with logging enabled
  final transport = NearbyTransport(
    localNodeId: nodeId,
    serviceId: ServiceId('com.example.nearbychat'),
    displayName: deviceName,
    onLog: nearbyLogCallback,
  );

  // Create Coordinator with in-memory storage
  final coordinator = await Coordinator.create(
    localNode: nodeId,
    channelRepository: InMemoryChannelRepository(),
    peerRepository: InMemoryPeerRepository(),
    entryRepository: InMemoryEntryRepository(),
    messagePort: transport.messagePort,
    timerPort: RealTimePort(),
  );

  // Create services
  final chatService = ChatService(
    coordinator: coordinator,
    localNodeId: nodeId,
    displayName: deviceName,
  );
  final connectionService = ConnectionService(
    transport: transport,
    coordinator: coordinator,
  );

  // Create controller
  final controller = ChatController(
    chatService: chatService,
    connectionService: connectionService,
    coordinator: coordinator,
  );

  // Create and start debug logger for observability
  final debugLogger = DebugLogger(
    coordinator: coordinator,
    transport: transport,
  );
  debugLogger.start();

  // Start the coordinator
  await coordinator.start();

  // Run the app
  runApp(ChatApp(controller: controller));
}

Future<String> _getDeviceName() async {
  final deviceInfo = DeviceInfoPlugin();

  try {
    final androidInfo = await deviceInfo.androidInfo;
    return androidInfo.model;
  } catch (_) {}

  try {
    final iosInfo = await deviceInfo.iosInfo;
    return iosInfo.name;
  } catch (_) {}

  return 'Unknown Device';
}
