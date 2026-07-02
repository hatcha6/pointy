import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/design/design.dart';

/// Filled/empty dots showing how many PIN digits have been entered.
class PriceCheckerPinDots extends StatelessWidget {
  const PriceCheckerPinDots({
    super.key,
    required this.length,
    required this.filled,
    this.error = false,
  });

  final int length;
  final int filled;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final active = error ? colors.danger : colors.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (index) {
        final isFilled = index < filled;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 7),
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isFilled ? active : Colors.transparent,
            border: Border.all(
              color: isFilled ? active : colors.lineStrong,
              width: 2,
            ),
          ),
        );
      }),
    );
  }
}

/// A clean on-screen numeric keypad — robust for kiosks that have no keyboard
/// beyond the barcode scanner.
class PriceCheckerKeypad extends StatelessWidget {
  const PriceCheckerKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    this.maxWidth = 320,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.5,
        children: [
          for (var digit = 1; digit <= 9; digit++)
            _KeypadButton(label: '$digit', onTap: () => onDigit('$digit')),
          const SizedBox.shrink(),
          _KeypadButton(label: '0', onTap: () => onDigit('0')),
          _KeypadButton(icon: Icons.backspace_outlined, onTap: onBackspace),
        ],
      ),
    );
  }
}

class _KeypadButton extends StatelessWidget {
  const _KeypadButton({this.label, this.icon, required this.onTap});

  final String? label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Material(
      color: colors.subtleFill,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Center(
          child: icon != null
              ? Icon(icon, size: 26, color: colors.ink)
              : Text(
                  label!,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    color: colors.ink,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Prompts for the exit PIN over the kiosk. Returns `true` once the entered PIN
/// passes [verify]; `false`/`null` if the user cancels.
Future<bool> showPriceCheckerExitDialog(
  BuildContext context, {
  required bool Function(String pin) verify,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _ExitPinDialog(verify: verify),
  );
  return result ?? false;
}

class _ExitPinDialog extends StatefulWidget {
  const _ExitPinDialog({required this.verify});

  final bool Function(String pin) verify;

  @override
  State<_ExitPinDialog> createState() => _ExitPinDialogState();
}

class _ExitPinDialogState extends State<_ExitPinDialog> {
  String _pin = '';
  bool _error = false;

  void _digit(String value) {
    if (_pin.length >= 6) return;
    setState(() {
      _pin += value;
      _error = false;
    });
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = false;
    });
  }

  void _confirm() {
    if (widget.verify(_pin)) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _error = true;
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: colors.surface,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline_rounded, size: 40, color: colors.primary),
              const SizedBox(height: 12),
              Text(
                l10n.priceCheckerExitTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: colors.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _error
                    ? l10n.priceCheckerWrongPin
                    : l10n.priceCheckerExitSubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: _error ? colors.danger : colors.mutedInk,
                ),
              ),
              const SizedBox(height: 20),
              PriceCheckerPinDots(
                length: 6,
                filled: _pin.length,
                error: _error,
              ),
              const SizedBox(height: 24),
              PriceCheckerKeypad(onDigit: _digit, onBackspace: _backspace),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(l10n.cancelButton),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _pin.isEmpty ? null : _confirm,
                      child: Text(l10n.confirmButton),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
