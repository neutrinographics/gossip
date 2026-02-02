import 'dart:async';

/// Serializes write operations per device.
///
/// BLE GATT operations must be sequential - concurrent writes to the same
/// device cause errors on Android (IllegalStateException) and may destabilize
/// the connection. This queue ensures writes to the same device are serialized
/// while allowing parallel writes to different devices.
class WriteQueue {
  final Map<String, _DeviceQueue> _queues = {};

  /// Enqueues a write operation for the given device.
  ///
  /// The operation will execute immediately if no other operation is in
  /// progress for this device. Otherwise, it waits for previous operations
  /// to complete.
  ///
  /// Returns when the operation completes. Throws if the operation throws.
  Future<void> enqueue(String deviceId, Future<void> Function() operation) {
    final queue = _queues.putIfAbsent(deviceId, _DeviceQueue.new);
    return queue.enqueue(operation);
  }

  /// Clears pending operations for a device.
  ///
  /// The currently executing operation (if any) will complete, but pending
  /// operations will be cancelled.
  void clear(String deviceId) {
    _queues[deviceId]?.clear();
  }

  /// Disposes all queues.
  void dispose() {
    for (final queue in _queues.values) {
      queue.clear();
    }
    _queues.clear();
  }
}

class _DeviceQueue {
  Future<void>? _current;
  final List<_PendingOperation> _pending = [];
  bool _cleared = false;

  Future<void> enqueue(Future<void> Function() operation) {
    final completer = Completer<void>();
    final pending = _PendingOperation(operation, completer);

    if (_current == null) {
      _execute(pending);
    } else {
      _pending.add(pending);
    }

    return completer.future;
  }

  void _execute(_PendingOperation pending) {
    _current = pending
        .operation()
        .then((_) {
          pending.completer.complete();
        })
        .catchError((Object error, StackTrace stack) {
          pending.completer.completeError(error, stack);
        })
        .whenComplete(() {
          _current = null;
          _processNext();
        });
  }

  void _processNext() {
    if (_pending.isEmpty || _cleared) return;
    final next = _pending.removeAt(0);
    if (!next.completer.isCompleted) {
      _execute(next);
    } else {
      _processNext();
    }
  }

  void clear() {
    _cleared = true;
    for (final pending in _pending) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          StateError('Queue cleared'),
          StackTrace.current,
        );
      }
    }
    _pending.clear();
    _cleared = false;
  }
}

class _PendingOperation {
  final Future<void> Function() operation;
  final Completer<void> completer;

  _PendingOperation(this.operation, this.completer);
}
