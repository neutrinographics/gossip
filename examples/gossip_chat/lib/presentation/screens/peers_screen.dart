import 'package:flutter/material.dart';

import '../../application/services/indirect_peer_service.dart';
import '../controllers/chat_controller.dart';
import '../view_models/view_models.dart';
import '../widgets/animated_empty_state.dart';
import '../widgets/node_avatar.dart';
import '../widgets/signal_strength_indicator.dart';

class PeersScreen extends StatelessWidget {
  final ChatController controller;

  const PeersScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Nearby Peers')),
          body: Column(
            children: [
              Expanded(
                child: controller.peers.isEmpty
                    ? _buildEmptyState()
                    : _buildPeerList(),
              ),
              _buildControls(context),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    final status = controller.connectionStatus;
    final isSearching =
        status == ConnectionStatus.discovering ||
        status == ConnectionStatus.advertising;

    return AnimatedEmptyState(
      icon: isSearching ? Icons.radar : Icons.people_outline,
      title: isSearching ? 'Searching for peers...' : 'No peers found',
      subtitle: isSearching
          ? 'Looking for nearby devices'
          : 'Start discovery to find nearby devices',
    );
  }

  Widget _buildPeerList() {
    final hasIndirectPeers = controller.indirectPeers.isNotEmpty;

    return ListView(
      children: [
        // Direct peers section
        ...controller.peers.map((peer) => _PeerTile(peer: peer)),

        // Indirect peers section
        if (hasIndirectPeers) ...[
          const _SectionHeader(title: 'Indirect Peers'),
          ...controller.indirectPeers.map(
            (peer) => _IndirectPeerTile(peer: peer),
          ),
        ],
      ],
    );
  }

  Widget _buildControls(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final status = controller.connectionStatus;
    final isActive =
        status == ConnectionStatus.discovering ||
        status == ConnectionStatus.advertising ||
        status == ConnectionStatus.connected;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: isActive
                ? controller.stopNetworking
                : () => _handleStartNetworking(context),
            icon: Icon(isActive ? Icons.stop : Icons.play_arrow),
            label: Text(isActive ? 'Stop Discovery' : 'Start Discovery'),
            style: ElevatedButton.styleFrom(
              backgroundColor: isActive ? colorScheme.error : null,
              foregroundColor: isActive ? colorScheme.onError : null,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleStartNetworking(BuildContext context) async {
    final success = await controller.startNetworking();
    if (!success && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Permissions required for Nearby Connections. '
            'Please grant Bluetooth and Location permissions.',
          ),
          duration: Duration(seconds: 4),
        ),
      );
    }
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

class _PeerTile extends StatelessWidget {
  final PeerState peer;

  const _PeerTile({required this.peer});

  @override
  Widget build(BuildContext context) {
    final statusText = switch (peer.status) {
      PeerConnectionStatus.connected => 'Connected',
      PeerConnectionStatus.suspected => 'Connection unstable',
      PeerConnectionStatus.unreachable => 'Disconnected',
    };

    return ListTile(
      leading: NodeAvatar(
        identifier: peer.id.value,
        displayText: peer.displayName,
        radius: 20,
      ),
      title: Text(peer.displayName),
      subtitle: Text(statusText),
      trailing: peer.status == PeerConnectionStatus.unreachable
          ? Icon(
              Icons.signal_cellular_off,
              size: 18,
              color: Theme.of(context).colorScheme.outline,
            )
          : SignalStrengthIndicator(strength: peer.signalStrength),
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
