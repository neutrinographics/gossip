import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/gossip_nearby.dart';

import 'app.dart';
import 'application/application.dart';
import 'presentation/presentation.dart';

/// Set to true for verbose logging (metrics, sync details, etc.)
const _verboseLogging = true;

/// Global debug logger instance for access from callbacks and UI.
late final DebugLogger debugLogger;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Configure log levels
  nearbyMinLogLevel = _verboseLogging ? LogLevel.trace : LogLevel.warning;

  // Generate or load device identity
  final localNodeRepo = InMemoryLocalNodeRepository();
  final deviceName = await _getDeviceName();

  // Create NearbyTransport for Android Nearby Connections
  final transport = await NearbyTransport.create(
    localNodeRepository: localNodeRepo,
    serviceId: ServiceId('gossipchat'),
    displayName: deviceName,
    onLog: nearbyLogCallback,
  );
  final nodeId = transport.localNodeId;

  // Create Coordinator with in-memory storage
  final coordinator = await Coordinator.create(
    localNodeRepository: localNodeRepo,
    channelRepository: InMemoryChannelRepository(),
    peerRepository: InMemoryPeerRepository(),
    entryRepository: InMemoryEntryRepository(),
    messagePort: transport.messagePort,
    timerPort: RealTimePort(),
    onLog: _verboseLogging ? gossipLogCallback : null,
  );

  // Create application services
  final chatService = ChatService(
    coordinator: coordinator,
    localNodeId: nodeId,
    displayName: deviceName,
    onError: (operation, error) {
      // ignore: avoid_print
      print('[ChatService] Error in $operation: $error');
    },
  );
  final connectionService = ConnectionService(
    transport: transport,
    coordinator: coordinator,
  );
  final syncService = SyncService(coordinator: coordinator);
  final metricsService = MetricsService(
    syncService: syncService,
    connectionService: connectionService,
  );

  // Create presentation controller
  final controller = ChatController(
    chatService: chatService,
    connectionService: connectionService,
    syncService: syncService,
    metricsService: metricsService,
  );

  // Create and start debug logger for observability
  debugLogger = DebugLogger(
    syncService: syncService,
    connectionService: connectionService,
    localNodeId: nodeId,
    deviceName: deviceName,
    logLevel: _verboseLogging ? DebugLogLevel.verbose : DebugLogLevel.error,
  );

  // Wire up global storage for callbacks to use
  globalLogStorage = debugLogger.storage;

  debugLogger.start();

  // Start the coordinator
  await coordinator.start();

  // Start networking (advertising and discovery)
  await controller.startNetworking();

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
