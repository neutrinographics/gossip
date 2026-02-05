import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Dialog that displays a QR code for sharing a channel.
class QrCodeDialog extends StatelessWidget {
  final String channelId;
  final String channelName;

  const QrCodeDialog({
    super.key,
    required this.channelId,
    required this.channelName,
  });

  /// Shows the QR code dialog.
  static Future<void> show(
    BuildContext context, {
    required String channelId,
    required String channelName,
  }) {
    return showDialog(
      context: context,
      builder: (context) =>
          QrCodeDialog(channelId: channelId, channelName: channelName),
    );
  }

  void _copyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: channelId));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Channel ID copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(channelName),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SizedBox(
              width: 200,
              height: 200,
              child: QrImageView(
                data: channelId,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Scan to join this channel',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            channelId,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: Colors.grey,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () => _copyToClipboard(context),
          icon: const Icon(Icons.copy),
          label: const Text('Copy ID'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
