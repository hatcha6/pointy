import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/services/auto_start_service.dart';
import '../../../shared/design/design.dart';

/// What the setup dialog collects. The caller applies it (configures the
/// controller, self-registers, toggles auto-start) so the dialog can close
/// cleanly before top-level routing swaps to the kiosk.
class PriceCheckerSetupResult {
  const PriceCheckerSetupResult({
    required this.pin,
    required this.deviceName,
    required this.location,
    required this.autoStart,
  });

  final String pin;
  final String deviceName;
  final String location;
  final bool autoStart;
}

/// First-time price-checker setup: name/location, a PIN (entered twice), and —
/// on Windows — whether to launch automatically at startup. Returns null if the
/// user cancels.
Future<PriceCheckerSetupResult?> showPriceCheckerSetupDialog(
  BuildContext context, {
  String initialName = '',
  String initialLocation = '',
}) {
  return showDialog<PriceCheckerSetupResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _PriceCheckerSetupDialog(
      initialName: initialName,
      initialLocation: initialLocation,
    ),
  );
}

class _PriceCheckerSetupDialog extends StatefulWidget {
  const _PriceCheckerSetupDialog({
    required this.initialName,
    required this.initialLocation,
  });

  final String initialName;
  final String initialLocation;

  @override
  State<_PriceCheckerSetupDialog> createState() =>
      _PriceCheckerSetupDialogState();
}

class _PriceCheckerSetupDialogState extends State<_PriceCheckerSetupDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  late final TextEditingController _location = TextEditingController(
    text: widget.initialLocation,
  );
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirmPin = TextEditingController();

  final bool _autoStartSupported = const AutoStartService().isSupportedPlatform;
  bool _autoStart = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _location.dispose();
    _pin.dispose();
    _confirmPin.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = AppLocalizations.of(context)!;
    final pin = _pin.text.trim();
    if (pin.length < 4) {
      setState(() => _error = l10n.priceCheckerPinTooShort);
      return;
    }
    if (pin != _confirmPin.text.trim()) {
      setState(() => _error = l10n.priceCheckerPinMismatch);
      return;
    }
    Navigator.of(context).pop(
      PriceCheckerSetupResult(
        pin: pin,
        deviceName: _name.text.trim(),
        location: _location.text.trim(),
        autoStart: _autoStartSupported && _autoStart,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Row(
        children: [
          Icon(Icons.price_check_rounded, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(l10n.priceCheckerSetupTitle)),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.priceCheckerSetupSubtitle,
                style: TextStyle(color: colors.mutedInk, height: 1.4),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.priceCheckerDeviceNameLabel,
                  hintText: l10n.priceCheckerDeviceNameHint,
                  prefixIcon: const Icon(Icons.badge_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _location,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.priceCheckerLocationLabel,
                  prefixIcon: const Icon(Icons.place_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: l10n.priceCheckerPinLabel,
                  hintText: l10n.priceCheckerPinHint,
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _confirmPin,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: l10n.priceCheckerConfirmPinLabel,
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  counterText: '',
                ),
              ),
              if (_autoStartSupported) ...[
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _autoStart,
                  onChanged: (value) => setState(() => _autoStart = value),
                  title: Text(l10n.priceCheckerRunOnStartupLabel),
                  subtitle: Text(l10n.priceCheckerRunOnStartupHint),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(
                    color: colors.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(l10n.priceCheckerStartButton),
        ),
      ],
    );
  }
}
