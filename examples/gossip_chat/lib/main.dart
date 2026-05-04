import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import 'app.dart';
import 'application/application.dart';
import 'presentation/presentation.dart';

/// Set to true for verbose logging (metrics, sync details, etc.)
const _verboseLogging = true;

/// Global debug logger instance for access from callbacks and UI.
late final DebugLogger debugLogger;

/// gossip service UUID for the chat demo. Pick your own UUID for your
/// app — collisions across unrelated apps would have all instances
/// visible to each other at the BLE layer. The trailing 8 hex bytes
/// are arbitrary; the prefix is fixed across all gossip_chat installs.
final _serviceUuid = ServiceUuid('f0000000-0000-0000-0000-67c155b1ea7c');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Configure log levels
  blueyMinLogLevel = _verboseLogging ? LogLevel.trace : LogLevel.warning;

  // Generate or load device identity
  final localNodeRepo = InMemoryLocalNodeRepository();
  final deviceName = await _getDeviceName();

  // Create BlueyTransport for cross-platform BLE.
  final transport = await BlueyTransport.create(
    localNodeRepository: localNodeRepo,
    serviceUuid: _serviceUuid,
    displayName: deviceName,
    onLog: blueyLogCallback,
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
