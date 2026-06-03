import 'package:flutter/material.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../controllers/chat_controller.dart';
import 'animated_status_indicator.dart';

/// A status bar widget displaying the current connection status.
///
/// Shows the connection state (connected, discovering, advertising, disconnected)
/// with an animated indicator and a button to start networking.
class ConnectionStatusBar extends StatelessWidget {
  final ConnectionStatus status;
  final BluetoothAdapterState adapterState;
  final int peerCount;
  final VoidCallback onStart;

  const ConnectionStatusBar({
    super.key,
    required this.status,
    required this.adapterState,
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
          if (status == ConnectionStatus.disconnected ||
              status == ConnectionStatus.invalidated)
            TextButton(onPressed: onStart, child: const Text('Start')),
        ],
      ),
    );
  }

  StatusIndicatorState _mapToIndicatorState(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.connected:
        return StatusIndicatorState.connected;
      case ConnectionStatus.meshActive:
      case ConnectionStatus.discovering:
      case ConnectionStatus.discoveryStarting:
      case ConnectionStatus.discoveryStopping:
        return StatusIndicatorState.discovering;
      case ConnectionStatus.advertising:
      case ConnectionStatus.advertisingStarting:
      case ConnectionStatus.advertisingStopping:
        return StatusIndicatorState.advertising;
      case ConnectionStatus.disconnected:
      case ConnectionStatus.bluetoothOff:
      case ConnectionStatus.invalidated:
        return StatusIndicatorState.disconnected;
    }
  }

  String _getStatusText() {
    switch (status) {
      case ConnectionStatus.connected:
        return '$peerCount peer${peerCount == 1 ? '' : 's'} connected';
      case ConnectionStatus.meshActive:
        return 'Listening for peers';
      case ConnectionStatus.discovering:
        return 'Discovering...';
      case ConnectionStatus.discoveryStarting:
        return 'Starting discovery...';
      case ConnectionStatus.discoveryStopping:
        return 'Stopping...';
      case ConnectionStatus.advertising:
        return 'Advertising...';
      case ConnectionStatus.advertisingStarting:
        return 'Starting advertising...';
      case ConnectionStatus.advertisingStopping:
        return 'Stopping...';
      case ConnectionStatus.disconnected:
        return 'Disconnected';
      case ConnectionStatus.invalidated:
        return 'Bluetooth restarted — tap Start to recover';
      case ConnectionStatus.bluetoothOff:
        switch (adapterState) {
          case BluetoothAdapterState.unauthorized:
            return 'Bluetooth permission required';
          case BluetoothAdapterState.unsupported:
            return 'Bluetooth not supported';
          case BluetoothAdapterState.off:
          case BluetoothAdapterState.unknown:
          case BluetoothAdapterState.on:
            return 'Bluetooth is off';
        }
    }
  }
}
