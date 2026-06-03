import 'dart:async';

import '../../domain/interfaces/bluey_port.dart';
import '../../domain/value_objects/ble_address.dart';
import '../../domain/value_objects/scan_candidate.dart';
import '../../domain/value_objects/service_uuid.dart';

/// Owns the BLE scan subscription and the current-candidates map. Emits
/// per-candidate events and replay-current snapshot streams. Does not
/// decide whether to connect — connection decisions are made elsewhere
/// (an auto-connect policy in mesh mode, or the consumer's explicit
/// `connectTo` call in manual mode).
class DiscoveryService {
  DiscoveryService({
    required BlueyPort port,
    required ServiceUuid serviceUuid,
  })  : _port = port,
        _serviceUuid = serviceUuid;

  final BlueyPort _port;
  final ServiceUuid _serviceUuid;

  // Cancelled in [stop] and [dispose].
  // ignore: cancel_subscriptions
  StreamSubscription<ScanCandidate>? _sub;
  final Map<BleAddress, ScanCandidate> _current = {};

  final StreamController<ScanCandidate> _events =
      StreamController<ScanCandidate>.broadcast();
  final StreamController<List<ScanCandidate>> _snapshotChanges =
      StreamController<List<ScanCandidate>>.broadcast();

  bool _disposed = false;

  bool get isRunning => _sub != null;

  /// Per-candidate stream. One emission per scan event from the
  /// underlying port.
  Stream<ScanCandidate> get candidates => _events.stream;

  /// Snapshot stream. Emits the current map values whenever the set
  /// changes. Replays the current value on subscribe.
  Stream<List<ScanCandidate>> get snapshots => Stream.multi((controller) {
        controller.add(List.unmodifiable(_current.values));
        final sub = _snapshotChanges.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = sub.cancel;
      });

  /// Immutable snapshot of the current candidate map values, in insertion
  /// order.
  List<ScanCandidate> get currentCandidates =>
      List.unmodifiable(_current.values);

  Future<void> start() async {
    if (_sub != null || _disposed) return;
    _sub = _port
        .scanForCandidates(serviceUuid: _serviceUuid)
        .listen(_onCandidate);
  }

  Future<void> stop() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    if (sub != null) {
      await _port.stopScan();
    }
    if (_current.isNotEmpty) {
      _current.clear();
      if (!_snapshotChanges.isClosed) {
        _snapshotChanges.add(const []);
      }
    }
  }

  void _onCandidate(ScanCandidate c) {
    _current[c.address] = c;
    if (!_events.isClosed) _events.add(c);
    if (!_snapshotChanges.isClosed) {
      _snapshotChanges.add(List.unmodifiable(_current.values));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _events.close();
    await _snapshotChanges.close();
  }
}
