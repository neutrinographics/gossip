import 'dart:typed_data';

/// Buffers BLE notifications that arrive before connection setup completes.
///
/// When a BLE central connects to a peripheral, notifications may arrive
/// before the connection is fully registered in the application layer.
/// This buffer stores those early notifications and replays them once
/// the connection setup is complete.
///
/// This solves the race condition where:
/// 1. Central connects and starts GATT service discovery
/// 2. Peripheral sends a notification (e.g., handshake)
/// 3. Notification arrives before service discovery completes
/// 4. Without buffering, the notification is lost
class NotificationBuffer {
  final Set<String> _setupInProgress = {};
  final Map<String, List<Uint8List>> _buffers = {};

  /// Marks that connection setup is in progress for a device.
  ///
  /// While setup is in progress, notifications will be buffered.
  void markSetupInProgress(String deviceId) {
    _setupInProgress.add(deviceId);
  }

  /// Marks that connection setup is complete for a device.
  ///
  /// After this, notifications will no longer be buffered.
  /// Call [flushBuffer] to retrieve any buffered notifications.
  void markSetupComplete(String deviceId) {
    _setupInProgress.remove(deviceId);
  }

  /// Returns whether setup is in progress for a device.
  bool isSetupInProgress(String deviceId) {
    return _setupInProgress.contains(deviceId);
  }

  /// Returns all device IDs that currently have setup in progress.
  Iterable<String> get setupInProgressIds => _setupInProgress;

  /// Buffers a notification if setup is in progress for the device.
  ///
  /// Returns true if the notification was buffered, false if it should
  /// be processed normally.
  bool bufferIfNeeded(String deviceId, Uint8List data) {
    if (!_setupInProgress.contains(deviceId)) {
      return false;
    }

    _buffers.putIfAbsent(deviceId, () => []).add(data);
    return true;
  }

  /// Flushes and returns all buffered notifications for a device.
  ///
  /// Returns notifications in the order they were received.
  /// The buffer is cleared after flushing.
  List<Uint8List> flushBuffer(String deviceId) {
    final buffered = _buffers.remove(deviceId);
    return buffered ?? [];
  }

  /// Clears all state for a device.
  void clear(String deviceId) {
    _setupInProgress.remove(deviceId);
    _buffers.remove(deviceId);
  }

  /// Disposes all buffers and state.
  void dispose() {
    _setupInProgress.clear();
    _buffers.clear();
  }
}
