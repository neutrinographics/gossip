import 'package:flutter/material.dart';

import '../controllers/chat_controller.dart';
import 'animated_status_indicator.dart';

/// A status bar widget displaying the current connection status.
///
/// Shows the connection state (connected, discovering, advertising, disconnected)
/// with an animated indicator and a button to start networking.
class ConnectionStatusBar extends StatelessWidget {
  final ConnectionStatus status;
  final int peerCount;
  final VoidCallback onStart;

  const ConnectionStatusBar({
    super.key,
    required this.status,
    required this.peerCount,
    required this.onStart,
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
      child: Row(
        children: [
          AnimatedStatusIndicator(
            state: _mapToIndicatorState(status),
            size: 14,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _getStatusText(),
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
          if (status == ConnectionStatus.disconnected)
            TextButton(onPressed: onStart, child: const Text('Start')),
        ],
      ),
    );
  }

  StatusIndicatorState _mapToIndicatorState(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.connected:
        return StatusIndicatorState.connected;
      case ConnectionStatus.discovering:
        return StatusIndicatorState.discovering;
      case ConnectionStatus.advertising:
        return StatusIndicatorState.advertising;
      case ConnectionStatus.disconnected:
        return StatusIndicatorState.disconnected;
    }
  }

  String _getStatusText() {
    switch (status) {
      case ConnectionStatus.connected:
        return '$peerCount peer${peerCount == 1 ? '' : 's'} connected';
      case ConnectionStatus.discovering:
        return 'Discovering...';
      case ConnectionStatus.advertising:
        return 'Advertising...';
      case ConnectionStatus.disconnected:
        return 'Disconnected';
    }
  }
}
