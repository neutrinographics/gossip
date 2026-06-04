import 'package:flutter/material.dart';

import '../view_models/discovered_peer.dart';

/// Small rounded badge that renders one of [DiscoveredPeerStatus]'s
/// seven values as a label + color + (for transient states) a spinner.
class PeerStatusPill extends StatelessWidget {
  final DiscoveredPeerStatus status;

  const PeerStatusPill({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final (label, fg, bg, isTransient) = switch (status) {
      DiscoveredPeerStatus.discovered => (
          'Nearby',
          colorScheme.onSurfaceVariant,
          colorScheme.surfaceContainerHigh,
          false,
        ),
      DiscoveredPeerStatus.connecting => (
          'Connecting…',
          colorScheme.onPrimaryContainer,
          colorScheme.primaryContainer,
          true,
        ),
      DiscoveredPeerStatus.connected => (
          'Connected',
          colorScheme.onPrimaryContainer,
          colorScheme.primaryContainer,
          false,
        ),
      DiscoveredPeerStatus.suspected => (
          'Unstable',
          colorScheme.onTertiaryContainer,
          colorScheme.tertiaryContainer,
          false,
        ),
      DiscoveredPeerStatus.unreachable => (
          'Disconnected',
          colorScheme.onSurfaceVariant,
          colorScheme.surfaceContainerHigh,
          false,
        ),
      DiscoveredPeerStatus.disconnecting => (
          'Disconnecting…',
          colorScheme.onTertiaryContainer,
          colorScheme.tertiaryContainer,
          true,
        ),
      DiscoveredPeerStatus.failed => (
          'Failed',
          colorScheme.onErrorContainer,
          colorScheme.errorContainer,
          false,
        ),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isTransient) ...[
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor: AlwaysStoppedAnimation(fg),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: fg),
            ),
          ],
        ),
      ),
    );
  }
}
