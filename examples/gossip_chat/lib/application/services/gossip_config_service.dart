import 'package:flutter/foundation.dart';
import 'package:gossip/gossip.dart';

/// Holds user-tunable gossip-timing knobs. Pure in-memory state; not
/// persisted across app launches.
///
/// Changes take effect on the NEXT call to [Coordinator.create] (i.e.
/// when the user restarts networking). This service does not attempt
/// live reconfiguration — `Coordinator` doesn't yet expose that surface.
class GossipConfigService extends ChangeNotifier {
  GossipConfigService();

  Duration? _gossipInterval; // null = adaptive
  Duration? _probeInterval; // null = adaptive

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
