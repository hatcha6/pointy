import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/cart_line.dart';

/// Edits the free-text kitchen note for a cart line. Returns the new note
/// (possibly empty, to clear it) or null when the dialog is dismissed.
Future<String?> showCartLineNoteSheet(
  BuildContext context, {
  required CartLine line,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _CartLineNoteDialog(line: line),
  );
}

class _CartLineNoteDialog extends StatefulWidget {
  const _CartLineNoteDialog({required this.line});

  final CartLine line;

  @override
  State<_CartLineNoteDialog> createState() => _CartLineNoteDialogState();
}

class _CartLineNoteDialogState extends State<_CartLineNoteDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.line.notes,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      icon: const Icon(Icons.sticky_note_2_outlined),
      title: Text(l10n.cartLineNoteDialogTitle),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 255,
          minLines: 1,
          maxLines: 3,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: widget.line.variant.productLabel,
            hintText: l10n.cartLineNoteHint,
            isDense: true,
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }
}
