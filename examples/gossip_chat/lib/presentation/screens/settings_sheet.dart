import 'package:flutter/material.dart';

import '../../application/services/gossip_config_service.dart';

/// Modal bottom sheet exposing gossip-timing knobs.
///
/// Two sliders (gossip interval, SWIM probe interval). Each has an
/// "Adaptive" position at the left end (sets the value to null,
/// reverting to GossipEngine/FailureDetector adaptive defaults).
///
/// Changes take effect on the next call to Start Networking; an
/// optional [networkingActive] flag enables a footer hint.
class SettingsSheet extends StatefulWidget {
  final GossipConfigService config;
  final bool networkingActive;

  const SettingsSheet({
    super.key,
    required this.config,
    this.networkingActive = false,
  });

  /// Convenience: show as a modal bottom sheet.
  static Future<void> show(
    BuildContext context, {
    required GossipConfigService config,
    bool networkingActive = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SettingsSheet(
        config: config,
        networkingActive: networkingActive,
      ),
    );
  }

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  static const _minMs = 100.0;
  static const _maxMs = 5000.0;
  // Sentinel value used by the slider's left edge to represent "adaptive".
  static const _adaptiveSentinel = _minMs - 1;

  double _gossipSliderValue() {
    final d = widget.config.gossipInterval;
    return d == null ? _adaptiveSentinel : d.inMilliseconds.toDouble();
  }

  double _probeSliderValue() {
    final d = widget.config.probeInterval;
    return d == null ? _adaptiveSentinel : d.inMilliseconds.toDouble();
  }

  String _formatValue(double v) =>
      v == _adaptiveSentinel ? 'Adaptive' : '${v.round()} ms';

  void _onGossipChanged(double v) {
    widget.config.setGossipInterval(
      v == _adaptiveSentinel ? null : Duration(milliseconds: v.round()),
    );
    setState(() {});
  }

  void _onProbeChanged(double v) {
    widget.config.setProbeInterval(
      v == _adaptiveSentinel ? null : Duration(milliseconds: v.round()),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Sheet handle / title.
          Center(
            child: Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text('Gossip settings', style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),

          // Gossip interval slider.
          _SliderRow(
            label: 'Gossip round interval',
            valueLabel: _formatValue(_gossipSliderValue()),
            value: _gossipSliderValue(),
            min: _adaptiveSentinel,
            max: _maxMs,
            onChanged: _onGossipChanged,
            onReset: () => _onGossipChanged(_adaptiveSentinel),
          ),
          const SizedBox(height: 16),

          // SWIM probe slider.
          _SliderRow(
            label: 'SWIM probe interval',
            valueLabel: _formatValue(_probeSliderValue()),
            value: _probeSliderValue(),
            min: _adaptiveSentinel,
            max: _maxMs,
            onChanged: _onProbeChanged,
            onReset: () => _onProbeChanged(_adaptiveSentinel),
          ),
          const SizedBox(height: 24),

          if (widget.networkingActive)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Restart networking to apply.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;

  const _SliderRow({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            TextButton(
              onPressed: onReset,
              child: const Text('Adaptive'),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: ((max - min) / 50).round(),
                label: valueLabel,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 80,
              child: Text(
                valueLabel,
                textAlign: TextAlign.end,
                style: theme.textTheme.labelMedium,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
