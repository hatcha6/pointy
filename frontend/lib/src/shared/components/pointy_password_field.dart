import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

/// Password input with a show/hide affordance.
///
/// Obscured fields give no way to catch a typo, which on a shared POS terminal
/// usually means a failed sign-in with no clue why. The trailing toggle reveals
/// the text on demand; its tooltip doubles as the screen-reader label for the
/// icon-only button.
class PointyPasswordField extends StatefulWidget {
  const PointyPasswordField({
    super.key,
    required this.controller,
    required this.labelText,
    this.enabled = true,
    this.prefixIcon = Icons.lock_outline,
    this.textInputAction,
    this.autofillHints,
    this.validator,
    this.onFieldSubmitted,
  });

  final TextEditingController controller;
  final String labelText;
  final bool enabled;

  /// Set to `null` for forms whose other fields carry no leading icon.
  final IconData? prefixIcon;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onFieldSubmitted;

  @override
  State<PointyPasswordField> createState() => _PointyPasswordFieldState();
}

class _PointyPasswordFieldState extends State<PointyPasswordField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TextFormField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscured,
      textInputAction: widget.textInputAction,
      autofillHints: widget.autofillHints,
      validator: widget.validator,
      onFieldSubmitted: widget.onFieldSubmitted,
      decoration: InputDecoration(
        labelText: widget.labelText,
        prefixIcon: widget.prefixIcon == null ? null : Icon(widget.prefixIcon),
        suffixIcon: IconButton(
          onPressed: widget.enabled
              ? () => setState(() => _obscured = !_obscured)
              : null,
          tooltip: _obscured
              ? l10n.showPasswordTooltip
              : l10n.hidePasswordTooltip,
          icon: Icon(
            _obscured
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
        ),
      ),
    );
  }
}
