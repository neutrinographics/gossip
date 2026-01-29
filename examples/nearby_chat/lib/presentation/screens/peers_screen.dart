import 'package:flutter/material.dart';

import '../controllers/chat_controller.dart';
import '../view_models/view_models.dart';

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
              _buildControls(),
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

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isSearching ? Icons.radar : Icons.people_outline,
            size: 64,
            color: Colors.grey,
          ),
          const SizedBox(height: 16),
          Text(
            isSearching ? 'Searching for peers...' : 'No peers found',
            style: const TextStyle(fontSize: 18, color: Colors.grey),
          ),
          if (!isSearching) ...[
            const SizedBox(height: 8),
            const Text(
              'Start discovery to find nearby devices',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPeerList() {
    return ListView.builder(
      itemCount: controller.peers.length,
      itemBuilder: (context, index) {
        final peer = controller.peers[index];
        return _PeerTile(peer: peer);
      },
    );
  }

  Widget _buildControls() {
    final status = controller.connectionStatus;
    final isActive =
        status == ConnectionStatus.discovering ||
        status == ConnectionStatus.advertising ||
        status == ConnectionStatus.connected;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: SafeArea(
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: isActive
                ? controller.stopNetworking
                : controller.startNetworking,
            icon: Icon(isActive ? Icons.stop : Icons.play_arrow),
            label: Text(isActive ? 'Stop Discovery' : 'Start Discovery'),
            style: ElevatedButton.styleFrom(
              backgroundColor: isActive ? Colors.red : null,
              foregroundColor: isActive ? Colors.white : null,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
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
    final (icon, color, statusText) = switch (peer.status) {
      PeerConnectionStatus.connected => (
        Icons.circle,
        Colors.green,
        'Connected',
      ),
      PeerConnectionStatus.suspected => (
        Icons.circle,
        Colors.orange,
        'Connection unstable',
      ),
      PeerConnectionStatus.unreachable => (
        Icons.circle_outlined,
        Colors.grey,
        'Disconnected',
      ),
    };

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.2),
        child: Icon(Icons.person, color: color),
      ),
      title: Text(peer.displayName),
      subtitle: Text(statusText),
      trailing: Icon(icon, size: 12, color: color),
    );
  }
}
