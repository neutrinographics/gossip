import 'package:flutter/material.dart';

import '../../application/observability/log_format.dart';
import '../controllers/chat_controller.dart';
import '../view_models/metrics_state.dart';

/// Screen displaying sync metrics for debugging.
class MetricsScreen extends StatelessWidget {
  final ChatController controller;

  const MetricsScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final metrics = controller.metrics;
        return Scaffold(
          appBar: AppBar(title: const Text('Metrics')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _StorageSection(metrics: metrics),
              const SizedBox(height: 16),
              _NetworkSection(metrics: metrics),
              const SizedBox(height: 16),
              _TotalsSection(metrics: metrics),
              const SizedBox(height: 16),
              _PeersSection(metrics: metrics),
            ],
          ),
        );
      },
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SectionCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final IconData? icon;
  final String label;
  final String value;

  const _MetricRow({this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageSection extends StatelessWidget {
  final MetricsState metrics;

  const _StorageSection({required this.metrics});

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'STORAGE',
      children: [
        _MetricRow(
          icon: Icons.article_outlined,
          label: 'Entries',
          value: metrics.totalEntries.toString(),
        ),
        _MetricRow(
          icon: Icons.storage_outlined,
          label: 'Size',
          value: LogFormat.bytes(metrics.totalStorageBytes),
        ),
      ],
    );
  }
}

class _NetworkSection extends StatelessWidget {
  final MetricsState metrics;

  const _NetworkSection({required this.metrics});

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'NETWORK (30s avg)',
      children: [
        _MetricRow(
          icon: Icons.arrow_upward,
          label: 'Send rate',
          value: _formatRate(metrics.sendRateBytesPerSec),
        ),
        _MetricRow(
          icon: Icons.arrow_downward,
          label: 'Receive rate',
          value: _formatRate(metrics.receiveRateBytesPerSec),
        ),
      ],
    );
  }

  String _formatRate(double bytesPerSec) {
    if (bytesPerSec < 1) return '0 B/s';
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
}

class _TotalsSection extends StatelessWidget {
  final MetricsState metrics;

  const _TotalsSection({required this.metrics});

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'TOTALS',
      children: [
        _MetricRow(
          icon: Icons.arrow_upward,
          label: 'Sent',
          value: LogFormat.bytes(metrics.totalBytesSent),
        ),
        _MetricRow(
          icon: Icons.arrow_downward,
          label: 'Received',
          value: LogFormat.bytes(metrics.totalBytesReceived),
        ),
      ],
    );
  }
}

class _PeersSection extends StatelessWidget {
  final MetricsState metrics;

  const _PeersSection({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (metrics.peers.isEmpty) {
      return _SectionCard(
        title: 'PEERS',
        children: [
          Text(
            'No peers connected',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
    }

    return _SectionCard(
      title: 'PEERS (${metrics.peers.length})',
      children: [for (final peer in metrics.peers) _PeerTile(peer: peer)],
    );
  }
}

class _PeerTile extends StatelessWidget {
  final PeerMetricsState peer;

  const _PeerTile({required this.peer});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.person_outline,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              peer.displayName,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          _TransferBadge(
            icon: Icons.arrow_upward,
            value: LogFormat.bytes(peer.bytesSent),
          ),
          const SizedBox(width: 8),
          _TransferBadge(
            icon: Icons.arrow_downward,
            value: LogFormat.bytes(peer.bytesReceived),
          ),
        ],
      ),
    );
  }
}

class _TransferBadge extends StatelessWidget {
  final IconData icon;
  final String value;

  const _TransferBadge({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 2),
        Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
