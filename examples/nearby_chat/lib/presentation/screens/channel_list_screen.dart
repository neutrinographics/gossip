import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../infrastructure/services/permission_service.dart';
import '../controllers/chat_controller.dart';
import '../theme/theme.dart';
import '../view_models/view_models.dart';
import '../widgets/widgets.dart';
import 'chat_screen.dart';
import 'peers_screen.dart';
import 'qr_scanner_screen.dart';

class ChannelListScreen extends StatelessWidget {
  final ChatController controller;
  final ThemeController themeController;

  const ChannelListScreen({
    super.key,
    required this.controller,
    required this.themeController,
  });

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
                icon: Icon(
                  themeController.isDarkMode(context)
                      ? Icons.light_mode
                      : Icons.dark_mode,
                ),
                onPressed: () => themeController.toggleTheme(context),
                tooltip: 'Toggle theme',
              ),
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
              ConnectionStatusBar(
                status: controller.connectionStatus,
                peerCount: controller.peers.length,
                onStart: controller.startNetworking,
                onStop: controller.stopNetworking,
              ),
            ],
          ),
          floatingActionButton: Padding(
            // Offset to float above the ConnectionStatusBar
            padding: const EdgeInsets.only(bottom: 56),
            child: Row(
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
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return const AnimatedEmptyState(
      icon: Icons.chat_bubble_outline,
      title: 'No channels yet',
      subtitle: 'Create a channel or join an existing one',
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
    showDialog(
      context: context,
      builder: (_) => TextInputDialog(
        title: 'Create Channel',
        labelText: 'Channel name',
        hintText: 'e.g., General',
        confirmText: 'Create',
        onConfirm: controller.createChannel,
      ),
    );
  }

  void _showJoinChannelDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => TextInputDialog(
        title: 'Join Channel',
        labelText: 'Channel ID',
        hintText: 'Paste the channel ID here',
        confirmText: 'Join',
        onConfirm: controller.joinChannel,
        extraContent: OutlinedButton.icon(
          onPressed: () => _scanQrCode(context, dialogContext),
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan QR Code'),
        ),
      ),
    );
  }

  Future<void> _scanQrCode(
    BuildContext context,
    BuildContext dialogContext,
  ) async {
    // Request camera permission
    final permissionService = PermissionService();
    final hasPermission = await permissionService.requestCameraPermission();
    if (!hasPermission) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission is required')),
        );
      }
      return;
    }

    // Close the dialog first
    if (dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }

    // Open scanner
    if (context.mounted) {
      final channelId = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const QrScannerScreen()),
      );

      if (channelId != null) {
        controller.joinChannel(channelId);
      }
    }
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
    final theme = Theme.of(context);

    return ListTile(
      leading: Hero(
        tag: 'channel_icon_${channel.id.value}',
        child: NodeAvatar(
          identifier: channel.id.value,
          displayText: channel.name,
          radius: 20,
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Hero(
              tag: 'channel_name_${channel.id.value}',
              child: Material(
                color: Colors.transparent,
                child: Text(channel.name, style: theme.textTheme.bodyLarge),
              ),
            ),
          ),
          if (channel.unreadCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
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
