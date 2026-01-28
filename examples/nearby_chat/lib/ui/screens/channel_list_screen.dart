import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/chat_controller.dart';
import '../../models/models.dart';
import 'chat_screen.dart';
import 'peers_screen.dart';

class ChannelListScreen extends StatelessWidget {
  final ChatController controller;

  const ChannelListScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Nearby Chat'),
            actions: [
              IconButton(
                icon: const Icon(Icons.people),
                onPressed: () => _openPeersScreen(context),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: controller.channels.isEmpty
                    ? _buildEmptyState()
                    : _buildChannelList(context),
              ),
              _buildStatusBar(),
            ],
          ),
          floatingActionButton: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FloatingActionButton.extended(
                heroTag: 'join',
                onPressed: () => _showJoinChannelDialog(context),
                icon: const Icon(Icons.login),
                label: const Text('Join'),
              ),
              const SizedBox(width: 12),
              FloatingActionButton(
                heroTag: 'create',
                onPressed: () => _showCreateChannelDialog(context),
                child: const Icon(Icons.add),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'No channels yet',
            style: TextStyle(fontSize: 18, color: Colors.grey),
          ),
          SizedBox(height: 8),
          Text(
            'Create a channel or join an existing one',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelList(BuildContext context) {
    return ListView.builder(
      itemCount: controller.channels.length,
      itemBuilder: (context, index) {
        final channel = controller.channels[index];
        return _ChannelTile(
          channel: channel,
          onTap: () => _openChannel(context, channel),
          onLeave: () => _confirmLeaveChannel(context, channel),
          onCopyId: () => _copyChannelId(context, channel),
        );
      },
    );
  }

  Widget _buildStatusBar() {
    final status = controller.connectionStatus;
    final peerCount = controller.peers.length;

    IconData icon;
    Color color;
    String text;

    switch (status) {
      case ConnectionStatus.connected:
        icon = Icons.circle;
        color = Colors.green;
        text = '$peerCount peer${peerCount == 1 ? '' : 's'} connected';
      case ConnectionStatus.discovering:
        icon = Icons.search;
        color = Colors.orange;
        text = 'Discovering...';
      case ConnectionStatus.advertising:
        icon = Icons.broadcast_on_personal;
        color = Colors.blue;
        text = 'Advertising...';
      case ConnectionStatus.disconnected:
        icon = Icons.circle_outlined;
        color = Colors.grey;
        text = 'Disconnected';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 8),
          Text(text, style: TextStyle(color: Colors.grey.shade700)),
        ],
      ),
    );
  }

  void _openChannel(BuildContext context, ChannelState channel) {
    controller.selectChannel(channel.id);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(controller: controller)),
    );
  }

  void _openPeersScreen(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PeersScreen(controller: controller)),
    );
  }

  void _showCreateChannelDialog(BuildContext context) {
    final textController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Channel'),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Channel name',
            hintText: 'e.g., General',
          ),
          onSubmitted: (_) {
            if (textController.text.isNotEmpty) {
              controller.createChannel(textController.text);
              Navigator.of(context).pop();
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (textController.text.isNotEmpty) {
                controller.createChannel(textController.text);
                Navigator.of(context).pop();
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showJoinChannelDialog(BuildContext context) {
    final textController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join Channel'),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Channel ID',
            hintText: 'Paste the channel ID here',
          ),
          onSubmitted: (_) {
            if (textController.text.isNotEmpty) {
              controller.joinChannel(textController.text);
              Navigator.of(context).pop();
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (textController.text.isNotEmpty) {
                controller.joinChannel(textController.text);
                Navigator.of(context).pop();
              }
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  void _confirmLeaveChannel(BuildContext context, ChannelState channel) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave Channel'),
        content: Text(
          'Leave "${channel.name}"? You can rejoin later with the channel ID.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              controller.leaveChannel(channel.id);
              Navigator.of(context).pop();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
  }

  void _copyChannelId(BuildContext context, ChannelState channel) {
    Clipboard.setData(ClipboardData(text: channel.id.value));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Channel ID copied to clipboard')),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final ChannelState channel;
  final VoidCallback onTap;
  final VoidCallback onLeave;
  final VoidCallback onCopyId;

  const _ChannelTile({
    required this.channel,
    required this.onTap,
    required this.onLeave,
    required this.onCopyId,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.tag)),
      title: Row(
        children: [
          Expanded(child: Text(channel.name)),
          if (channel.unreadCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${channel.unreadCount}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
        ],
      ),
      subtitle: channel.lastMessage != null
          ? Text(
              channel.lastMessage!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 20),
        onPressed: onLeave,
      ),
      onTap: onTap,
      onLongPress: onCopyId,
    );
  }
}
