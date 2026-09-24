import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

/// A dialog that asks for one line of text and returns it, or null if the
/// person cancelled. An empty string is a real answer — "confirmed, no note".
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
class PointyTextEntryDialog extends StatefulWidget {
  const PointyTextEntryDialog({
    super.key,
    required this.title,
    required this.fieldLabel,
    required this.confirmLabel,
    this.initialValue = '',
    this.message,
    this.subject,
    this.icon,
    this.fieldPrefixIcon,
    this.fieldTextDirection,
    this.isDestructive = false,
  });

  final String title;
  final String fieldLabel;
  final String confirmLabel;
  final String initialValue;

  /// Explains what confirming will do, above the field.
  final String? message;

  /// The one thing the entry is about — a customer's name, a device — shown
  /// emphasised between the message and the field.
  final String? subject;

  final IconData? icon;
  final IconData? fieldPrefixIcon;

  /// Forces the field's direction, for values that are always Latin (an
  /// imported employee code) inside an otherwise right-to-left screen.
  final TextDirection? fieldTextDirection;

  /// Styles the confirm action as a danger action, for entries that accompany
  /// something irreversible (cancelling a job, and why).
  final bool isDestructive;

  @override
  State<PointyTextEntryDialog> createState() => _PointyTextEntryDialogState();
}

class _PointyTextEntryDialogState extends State<PointyTextEntryDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final message = widget.message;
    final subject = widget.subject;
    final icon = widget.icon;

    final field = TextField(
      controller: _controller,
      autofocus: true,
      textDirection: widget.fieldTextDirection,
      decoration: InputDecoration(
        labelText: widget.fieldLabel,
        prefixIcon: widget.fieldPrefixIcon == null
            ? null
            : Icon(widget.fieldPrefixIcon),
      ),
      onSubmitted: (_) => _submit(),
    );

    return AdaptiveDialogSurface(
      size: AdaptiveModalSize.compact,
      child: AlertDialog(
        // A long explanation plus the keyboard this field raises on a phone is
        // more than a short screen holds; scroll rather than overflow.
        scrollable: true,
        icon: icon == null
            ? null
            : Icon(
                icon,
                color: widget.isDestructive
                    ? colors.danger
                    : colors.primaryStrong,
              ),
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (message != null) ...[
              Text(message, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
            ],
            if (subject != null) ...[
              Text(
                subject,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
            ],
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
            style: widget.isDestructive
                ? FilledButton.styleFrom(
                    backgroundColor: colors.danger,
                    foregroundColor: colors.surface,
                  )
                : null,
            child: Text(widget.confirmLabel),
          ),
        ],
      ),
    );
  }
}
