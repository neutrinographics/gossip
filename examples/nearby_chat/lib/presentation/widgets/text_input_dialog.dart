import 'package:flutter/material.dart';

/// A reusable dialog with a text input field.
///
/// Provides consistent styling and behavior for dialogs that collect
/// text input from the user (e.g., create channel, join channel).
class TextInputDialog extends StatefulWidget {
  /// The dialog title.
  final String title;

  /// Label for the text field.
  final String labelText;

  /// Hint text shown when the field is empty.
  final String hintText;

  /// Text for the confirm button.
  final String confirmText;

  /// Optional extra content to show below the text field.
  final Widget? extraContent;

  /// Called when the user confirms with a non-empty value.
  final void Function(String value) onConfirm;

  const TextInputDialog({
    super.key,
    required this.title,
    required this.labelText,
    required this.hintText,
    required this.confirmText,
    required this.onConfirm,
    this.extraContent,
  });

  @override
  State<TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<TextInputDialog> {
  final _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _textController.text.trim();
    if (value.isNotEmpty) {
      widget.onConfirm(value);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _textController,
            autofocus: true,
            decoration: InputDecoration(
              labelText: widget.labelText,
              hintText: widget.hintText,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.extraContent != null) ...[
            const SizedBox(height: 16),
            widget.extraContent!,
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _submit, child: Text(widget.confirmText)),
      ],
    );
  }
}
