import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart';

/// Holds user-tunable gossip-timing knobs. Pure in-memory state; not
/// persisted across app launches.
///
/// Defaults are deliberately slower than gossip's adaptive baseline
/// (~500ms gossip, ~1s probe) to reduce wire traffic on BLE — fewer
/// multi-chunk DeltaResponses, smaller and less frequent bursts, and
/// less interaction with I343. The slider in the settings sheet still
/// lets the user tune back to adaptive or faster on demand.
///
/// Changes take effect on the NEXT call to [Coordinator.create] (i.e.
/// when the user restarts networking). This service does not attempt
/// live reconfiguration — `Coordinator` doesn't yet expose that surface.
class GossipConfigService extends ChangeNotifier {
  GossipConfigService({
    Duration? gossipInterval = const Duration(seconds: 2),
    Duration? probeInterval = const Duration(seconds: 3),
  })  : _gossipInterval = gossipInterval,
        _probeInterval = probeInterval;

  Duration? _gossipInterval;
  Duration? _probeInterval;

  /// Static gossip round interval. Null means adaptive.
  Duration? get gossipInterval => _gossipInterval;

  /// Static SWIM probe interval. Null means adaptive.
  Duration? get probeInterval => _probeInterval;

  void setGossipInterval(Duration? d) {
    if (_gossipInterval == d) return;
    _gossipInterval = d;
    notifyListeners();
  }

  void setProbeInterval(Duration? d) {
    if (_probeInterval == d) return;
    _probeInterval = d;
    notifyListeners();
  }

  /// Builds the [CoordinatorConfig] for the current values. Other
  /// CoordinatorConfig fields stay at their defaults (this service only
  /// owns timing knobs — startup grace, suspicion thresholds etc. are
  /// out of scope).
  CoordinatorConfig buildCoordinatorConfig() => CoordinatorConfig(
        gossipInterval: _gossipInterval,
        probeInterval: _probeInterval,
      );
}
