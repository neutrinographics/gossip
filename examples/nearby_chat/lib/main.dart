import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_nearby/gossip_nearby.dart';
import 'package:uuid/uuid.dart';

import 'app.dart';
import 'application/application.dart';
import 'presentation/presentation.dart';

/// Set to true for verbose logging (metrics, sync details, etc.)
const _verboseLogging = true;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Configure log levels
  nearbyMinLogLevel = _verboseLogging ? LogLevel.trace : LogLevel.warning;

  // Generate or load device identity
  final nodeId = NodeId(const Uuid().v4());
  final deviceName = await _getDeviceName();

  // Create NearbyTransport for Android Nearby Connections
  final transport = NearbyTransport(
    localNodeId: nodeId,
    serviceId: ServiceId('nearbychat'),
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
    onLog: _verboseLogging ? _logCallback : null,
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
  final debugLogger = DebugLogger(
    syncService: syncService,
    connectionService: connectionService,
    logLevel: _verboseLogging ? DebugLogLevel.verbose : DebugLogLevel.error,
  );
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

/// Unified log callback for gossip protocol messages.
void _logCallback(
  LogLevel level,
  String message, [
  Object? error,
  StackTrace? stackTrace,
]) {
  final levelStr = level.name.toUpperCase().padRight(7);
  final category = 'GOSSIP][$levelStr';
  var logLine = LogFormat.logLine(category, message);
  if (error != null) {
    logLine += ' | Error: $error';
  }
  // ignore: avoid_print
  print(logLine);
}
