import 'package:bluey/bluey.dart' as bluey;
import 'package:flutter/material.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

/// Bottom-of-screen control row for the peers screen.
///
/// Composes:
/// - A Mesh/Manual segmented control that flips
///   [ConnectionMode] via [onModeChanged].
/// - Two chips reflecting current advertising / scan state, driven by
///   [advertisingState] / [scanState]. Tapping a chip toggles the
///   corresponding lifecycle via [onToggleAdvertise] / [onToggleDiscover].
///
/// Chip behavior by state:
/// - `idle` / `stopped`: outlined, tappable, label "Advertise" / "Discover".
/// - `starting`: filled with spinner, label "Starting…", tap disabled.
/// - `advertising` / `scanning`: filled with check glyph, label
///   "Advertising" / "Discovering", tappable (taps stop).
/// - `stopping`: filled with spinner, label "Stopping…", tap disabled.
/// - `invalidated`: error-tinted with warning glyph, label "Reset …",
///   tappable (tap = restart via [onToggleAdvertise] / [onToggleDiscover]).
class TopologyControls extends StatelessWidget {
  final bluey.AdvertisingState advertisingState;
  final bluey.ScanState scanState;
  final ConnectionMode mode;
  final VoidCallback onToggleAdvertise;
  final VoidCallback onToggleDiscover;
  final ValueChanged<ConnectionMode> onModeChanged;
  final bool enabled;

  const TopologyControls({
    super.key,
    required this.advertisingState,
    required this.scanState,
    required this.mode,
    required this.onToggleAdvertise,
    required this.onToggleDiscover,
    required this.onModeChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Mesh / Manual segmented control.
            SegmentedButton<ConnectionMode>(
              segments: const [
                ButtonSegment(
                  value: ConnectionMode.manual,
                  label: Text('Manual'),
                  icon: Icon(Icons.touch_app_outlined),
                ),
                ButtonSegment(
                  value: ConnectionMode.auto,
                  label: Text('Mesh'),
                  icon: Icon(Icons.hub_outlined),
                ),
              ],
              selected: {mode},
              onSelectionChanged: enabled
                  ? (s) {
                      if (s.isNotEmpty) onModeChanged(s.first);
                    }
                  : null,
            ),
            const SizedBox(height: 8),
            // Advertise / Discover chips.
            Row(
              children: [
                Expanded(
                  child: _StateChip(
                    label: _advertiseLabel(advertisingState),
                    icon: _advertiseIcon(advertisingState),
                    active:
                        advertisingState == bluey.AdvertisingState.advertising,
                    invalidated:
                        advertisingState == bluey.AdvertisingState.invalidated,
                    transient:
                        advertisingState == bluey.AdvertisingState.starting ||
                            advertisingState ==
                                bluey.AdvertisingState.stopping,
                    onTap: enabled &&
                            advertisingState !=
                                bluey.AdvertisingState.starting &&
                            advertisingState !=
                                bluey.AdvertisingState.stopping
                        ? onToggleAdvertise
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StateChip(
                    label: _discoverLabel(scanState),
                    icon: _discoverIcon(scanState),
                    active: scanState == bluey.ScanState.scanning,
                    invalidated: scanState == bluey.ScanState.invalidated,
                    transient: scanState == bluey.ScanState.starting ||
                        scanState == bluey.ScanState.stopping,
                    onTap: enabled &&
                            scanState != bluey.ScanState.starting &&
                            scanState != bluey.ScanState.stopping
                        ? onToggleDiscover
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _advertiseLabel(bluey.AdvertisingState s) => switch (s) {
        bluey.AdvertisingState.idle => 'Advertise',
        bluey.AdvertisingState.starting => 'Starting…',
        bluey.AdvertisingState.advertising => 'Advertising',
        bluey.AdvertisingState.stopping => 'Stopping…',
        bluey.AdvertisingState.invalidated => 'Reset advertise',
      };

  IconData _advertiseIcon(bluey.AdvertisingState s) => switch (s) {
        bluey.AdvertisingState.idle => Icons.cell_tower_outlined,
        bluey.AdvertisingState.starting => Icons.hourglass_empty,
        bluey.AdvertisingState.advertising => Icons.check_circle_outline,
        bluey.AdvertisingState.stopping => Icons.hourglass_empty,
        bluey.AdvertisingState.invalidated => Icons.warning_amber_outlined,
      };

  String _discoverLabel(bluey.ScanState s) => switch (s) {
        bluey.ScanState.stopped => 'Discover',
        bluey.ScanState.starting => 'Starting…',
        bluey.ScanState.scanning => 'Discovering',
        bluey.ScanState.stopping => 'Stopping…',
        bluey.ScanState.invalidated => 'Reset discover',
      };

  IconData _discoverIcon(bluey.ScanState s) => switch (s) {
        bluey.ScanState.stopped => Icons.radar,
        bluey.ScanState.starting => Icons.hourglass_empty,
        bluey.ScanState.scanning => Icons.check_circle_outline,
        bluey.ScanState.stopping => Icons.hourglass_empty,
        bluey.ScanState.invalidated => Icons.warning_amber_outlined,
      };
}

class _StateChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final bool invalidated;
  final bool transient;
  final VoidCallback? onTap;

  const _StateChip({
    required this.label,
    required this.icon,
    required this.active,
    required this.invalidated,
    required this.transient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final (bg, fg, side) = invalidated
        ? (
            colorScheme.errorContainer,
            colorScheme.onErrorContainer,
            BorderSide(color: colorScheme.error),
          )
        : active
            ? (
                colorScheme.primaryContainer,
                colorScheme.onPrimaryContainer,
                BorderSide.none,
              )
            : (
                Colors.transparent,
                colorScheme.onSurface,
                BorderSide(color: colorScheme.outline),
              );

    Widget leading;
    if (transient) {
      leading = SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          valueColor: AlwaysStoppedAnimation(fg),
        ),
      );
    } else {
      leading = Icon(icon, size: 16, color: fg);
    }

    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: side,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              leading,
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
