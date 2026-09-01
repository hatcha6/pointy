import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../core/parsing.dart';
import '../decimal_text_input_formatter.dart';
import '../responsive/responsive.dart';

/// A dialog that asks for one number and returns it, or null if the person
/// cancelled.
///
/// It owns its [TextEditingController] and disposes it in its own `dispose()`,
/// which is the whole reason it exists as a widget rather than a closure. The
/// obvious shape —
///
/// ```dart
/// final controller = TextEditingController();
/// final value = await showDialog(...);
/// controller.dispose();
/// ```
///
/// is wrong, and wrong in a way that only shows up on a real device:
/// `showDialog` completes when the route is *popped*, while the dialog's exit
/// animation is still running and its `TextField` is still mounted. The next
/// frame rebuilds that field against a disposed controller, which throws
/// "A TextEditingController was used after being disposed" and then takes the
/// whole screen down with a framework assertion during teardown. Letting the
/// State own the controller ties its life to the route's, not to the await.
class PointyNumberEntryDialog extends StatefulWidget {
  const PointyNumberEntryDialog({
    super.key,
    required this.title,
    required this.initialValue,
    required this.isValid,
    this.icon,
    this.message,
    this.fieldLabel,
    this.suffixText,
    this.confirmLabel,
  });

  final String title;
  final String initialValue;

  /// Whether a parsed value may be returned. Submitting an invalid one does
  /// nothing rather than closing the dialog on a number the caller would reject.
  final bool Function(double value) isValid;

  final IconData? icon;
  final String? message;
  final String? fieldLabel;

  /// The unit the number is counted in, shown inside the field.
  final String? suffixText;

  /// Defaults to the generic confirm label.
  final String? confirmLabel;

  @override
  State<PointyNumberEntryDialog> createState() =>
      _PointyNumberEntryDialogState();
}

class _PointyNumberEntryDialogState extends State<PointyNumberEntryDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = parseDecimal(_controller.text);
    if (parsed == null || !widget.isValid(parsed)) {
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final message = widget.message;
    final hasDecoration =
        widget.fieldLabel != null || widget.suffixText != null;

    final field = TextField(
      controller: _controller,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [DecimalTextInputFormatter()],
      decoration: hasDecoration
          ? InputDecoration(
              labelText: widget.fieldLabel,
              suffixText: widget.suffixText,
            )
          : null,
      onSubmitted: (_) => _submit(),
    );

    return AdaptiveDialogSurface(
      size: AdaptiveModalSize.compact,
      child: AlertDialog(
        icon: widget.icon == null ? null : Icon(widget.icon),
        title: Text(widget.title),
        content: message == null
            ? field
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(message, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 12),
                  field,
                ],
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: _submit,
            child: Text(widget.confirmLabel ?? l10n.confirmButton),
          ),
        ],
      ),
    );
  }
}
