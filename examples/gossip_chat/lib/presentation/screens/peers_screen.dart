import 'package:flutter/material.dart';
import 'package:gossip_bluey/gossip_bluey.dart';

import '../../application/services/indirect_peer_service.dart';
import '../controllers/chat_controller.dart';
import '../view_models/view_models.dart';
import '../widgets/animated_empty_state.dart';
import '../widgets/ble_signal_indicator.dart';
import '../widgets/node_avatar.dart';
import '../widgets/peer_status_pill.dart';
import '../widgets/signal_strength_indicator.dart';
import '../widgets/topology_controls.dart';
import 'settings_sheet.dart';

/// Peers screen: lists nearby BLE peers and indirect peers (gossip-only),
/// each with its own dual-indicator row (BLE signal + gossip health), plus
/// a bottom [TopologyControls] panel that drives the BLE radio lifecycle.
class PeersScreen extends StatelessWidget {
  final ChatController controller;

  const PeersScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final hasDirect = controller.peers.isNotEmpty;
        final hasIndirect = controller.indirectPeers.isNotEmpty;
        final isEmpty = !hasDirect && !hasIndirect;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Nearby Peers'),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () => SettingsSheet.show(
                  context,
                  config: controller.configService,
                  networkingActive: controller.connectionStatus !=
                          ConnectionStatus.disconnected &&
                      controller.connectionStatus !=
                          ConnectionStatus.bluetoothOff,
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: isEmpty ? _buildEmptyState() : _buildPeerList(context),
              ),
              TopologyControls(
                advertisingState: controller.advertisingState,
                scanState: controller.scanState,
                mode: controller.connectionMode,
                onToggleAdvertise: () => controller.setAdvertising(
                  controller.advertisingState !=
                      AdvertisingState.advertising,
                ),
                onToggleDiscover: () => controller.setDiscovering(
                  controller.scanState != ScanState.scanning,
                ),
                onModeChanged: controller.setMode,
                enabled: controller.bluetoothAdapterState ==
                    BluetoothAdapterState.on,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    final status = controller.connectionStatus;
    if (status == ConnectionStatus.bluetoothOff) {
      switch (controller.bluetoothAdapterState) {
        case BluetoothAdapterState.unauthorized:
          return const AnimatedEmptyState(
            icon: Icons.bluetooth_disabled,
            title: 'Bluetooth permission required',
            subtitle: 'Grant Bluetooth permission in Settings to continue',
          );
        case BluetoothAdapterState.unsupported:
          return const AnimatedEmptyState(
            icon: Icons.bluetooth_disabled,
            title: 'Bluetooth not supported',
            subtitle: 'This device cannot use BLE peer discovery',
          );
        case BluetoothAdapterState.off:
        case BluetoothAdapterState.unknown:
        case BluetoothAdapterState.on:
          return const AnimatedEmptyState(
            icon: Icons.bluetooth_disabled,
            title: 'Bluetooth is off',
            subtitle: 'Turn Bluetooth on, then tap Discover',
          );
      }
    }
    final isSearching = controller.scanState == ScanState.scanning ||
        controller.scanState == ScanState.starting;
    return AnimatedEmptyState(
      icon: isSearching ? Icons.radar : Icons.people_outline,
      title: isSearching ? 'Searching for peers…' : 'No peers found',
      subtitle: isSearching
          ? 'Looking for nearby devices'
          : 'Tap Discover to start searching',
    );
  }

  Widget _buildPeerList(BuildContext context) {
    final hasDirect = controller.peers.isNotEmpty;
    final hasIndirect = controller.indirectPeers.isNotEmpty;
    final scanningActive =
        controller.scanState == ScanState.scanning;

    return ListView(
      children: [
        if (hasDirect) ...[
          const _SectionHeader(title: 'Nearby'),
          ...controller.peers.map(
            (peer) => _DiscoveredPeerTile(
              peer: peer,
              scanningActive: scanningActive,
              gossipProbeCount: peer.nodeId != null
                  ? controller.getSmoothedFailedProbeCount(peer.nodeId!)
                  : 0,
              onTap: () => _onPeerTap(context, peer),
            ),
          ),
        ],
        if (hasIndirect) ...[
          const _SectionHeader(title: 'Via gossip'),
          ...controller.indirectPeers.map(
            (peer) => _IndirectPeerTile(peer: peer),
          ),
        ],
      ],
    );
  }

  void _onPeerTap(BuildContext context, DiscoveredPeer peer) {
    switch (peer.status) {
      case DiscoveredPeerStatus.discovered:
      case DiscoveredPeerStatus.failed:
        controller.tapPeer(peer);
      case DiscoveredPeerStatus.connected:
      case DiscoveredPeerStatus.suspected:
      case DiscoveredPeerStatus.unreachable:
        _showConnectedActionSheet(context, peer);
      case DiscoveredPeerStatus.connecting:
      case DiscoveredPeerStatus.disconnecting:
        // Transient — ignore taps.
        return;
    }
  }

  void _showConnectedActionSheet(BuildContext context, DiscoveredPeer peer) {
    if (peer.nodeId == null) return;
    final nodeId = peer.nodeId!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('Disconnect'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                controller.disconnectPeer(nodeId);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// Row for a peer the local device has seen over BLE (directly discovered
/// or directly connected). Trailing edge carries TWO indicators side-by-side:
///   * [BleSignalIndicator] — RSSI-derived BLE link strength.
///   * [SignalStrengthIndicator] — gossip-protocol health (SWIM probes).
class _DiscoveredPeerTile extends StatelessWidget {
  final DiscoveredPeer peer;
  final bool scanningActive;
  final int gossipProbeCount;
  final VoidCallback onTap;

  const _DiscoveredPeerTile({
    required this.peer,
    required this.scanningActive,
    required this.gossipProbeCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final identifier = peer.nodeId?.value ?? peer.address.value;
    final displayName = peer.displayName ?? '(unknown)';

    final isConnected = peer.status == DiscoveredPeerStatus.connected ||
        peer.status == DiscoveredPeerStatus.suspected ||
        peer.status == DiscoveredPeerStatus.unreachable;
    final isOffline = peer.status == DiscoveredPeerStatus.unreachable ||
        peer.status == DiscoveredPeerStatus.failed;

    // Gossip health is only meaningful for peers we've actually connected
    // to (i.e. ones with a NodeId AND a non-failed status). Pre-handshake
    // or offline rows render a "no signal" glyph.
    final gossipStrength = switch (gossipProbeCount) {
      0 => 3,
      1 => 2,
      _ => 1,
    };
    final showGossipHealth = peer.nodeId != null && isConnected && !isOffline;

    final gossipIndicator = showGossipHealth
        ? SignalStrengthIndicator(strength: gossipStrength)
        : Icon(
            Icons.signal_cellular_off,
            size: 18,
            color: theme.colorScheme.outline,
          );

    return ListTile(
      leading: NodeAvatar(
        identifier: identifier,
        displayText: displayName,
        radius: 20,
      ),
      title: Text(displayName),
      subtitle: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: PeerStatusPill(status: peer.status),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BleSignalIndicator(
            health: BleHealth.fromRssi(peer.rssi),
            scanningActive: scanningActive,
          ),
          const SizedBox(width: 8),
          gossipIndicator,
        ],
      ),
      onTap: onTap,
    );
  }
}

class _IndirectPeerTile extends StatelessWidget {
  final IndirectPeerState peer;

  const _IndirectPeerTile({required this.peer});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (statusText, statusColor) = _getStatusInfo(theme);

    return ListTile(
      leading: NodeAvatar(
        identifier: peer.id.value,
        displayText: peer.displayName,
        radius: 20,
      ),
      title: Text(peer.displayName),
      subtitle: Text(statusText),
      trailing: _ActivityIndicator(
        status: peer.activityStatus,
        color: statusColor,
      ),
    );
  }

  (String, Color) _getStatusInfo(ThemeData theme) {
    return switch (peer.activityStatus) {
      IndirectPeerActivityStatus.active => ('Active', Colors.green),
      IndirectPeerActivityStatus.recent => ('Recently active', Colors.amber),
      IndirectPeerActivityStatus.away => ('Away', Colors.orange),
      IndirectPeerActivityStatus.stale => (
        'Inactive',
        theme.colorScheme.outline,
      ),
      IndirectPeerActivityStatus.unknown => (
        'Via gossip',
        theme.colorScheme.outline,
      ),
    };
  }
}

class _ActivityIndicator extends StatelessWidget {
  final IndirectPeerActivityStatus status;
  final Color color;

  const _ActivityIndicator({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: status == IndirectPeerActivityStatus.active
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.4),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
    );
  }
}
