import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/parsing.dart';
import '../../../core/result.dart';
import '../../../data/models/register_session.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/register_session_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/responsive/responsive.dart';

/// Opens the signed-in person's own drawer (register session) from a screen
/// that takes money outside the POS — a repair's invoice at closing time, after
/// the cashier has counted and closed theirs.
///
/// Money always lands in a drawer, and the server refuses a payment with no
/// drawer open (`register_session_required`). Only the POS knew how to open
/// one, so every other screen that takes money hit a wall one step from done:
/// the job could not be invoiced, so it could not be handed back. This is the
/// POS's own start step — the same opening cash, the same "required" setting —
/// offered where the money is, so the caller simply tries again.
///
/// Resolves true once a drawer is open; false when the person cancels, or may
/// not open one (then it says so instead of offering a button that 403s).
Future<bool> openRegisterSessionForPayment(
  BuildContext context, {
  required RegisterSessionRepository repository,
  required AuthorizationCapabilities capabilities,
  ShopSettingsRepository? shopSettingsRepository,
}) async {
  final l10n = AppLocalizations.of(context)!;
  if (!capabilities.canStartRegisterSession) {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.point_of_sale_outlined),
        title: Text(l10n.paymentDrawerTitle),
        content: Text(l10n.paymentDrawerNotAllowedMessage),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.closeButton),
          ),
        ],
      ),
    );
    return false;
  }

  // The POS assumes the stricter rule until the settings say otherwise.
  var requireOpeningCash = true;
  final settings = await shopSettingsRepository?.loadSettings();
  if (settings case Ok<ShopSettings>(:final value)) {
    requireOpeningCash = value.requireOpeningCash;
  }
  if (!context.mounted) {
    return false;
  }
  final opened = await showDialog<bool>(
    context: context,
    builder: (_) => OpenRegisterSessionDialog(
      repository: repository,
      requireOpeningCash: requireOpeningCash,
    ),
  );
  return opened ?? false;
}

/// The start step itself. Owns its controller (see [PointyNumberEntryDialog]
/// for why a caller-owned one breaks) and makes the call, so a failure stays
/// on screen with the typed amount instead of closing the dialog.
class OpenRegisterSessionDialog extends StatefulWidget {
  const OpenRegisterSessionDialog({
    super.key,
    required this.repository,
    required this.requireOpeningCash,
  });

  final RegisterSessionRepository repository;
  final bool requireOpeningCash;

  @override
  State<OpenRegisterSessionDialog> createState() =>
      _OpenRegisterSessionDialogState();
}

class _OpenRegisterSessionDialogState extends State<OpenRegisterSessionDialog> {
  final TextEditingController _openingCashController = TextEditingController();
  bool _isStarting = false;
  bool _showRequiredError = false;
  bool _failed = false;

  @override
  void dispose() {
    _openingCashController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final typed = _openingCashController.text.trim();
    if (widget.requireOpeningCash && typed.isEmpty) {
      setState(() => _showRequiredError = true);
      return;
    }
    setState(() {
      _isStarting = true;
      _failed = false;
    });
    final result = await widget.repository.startSession(
      openingCash: parseDecimal(typed) ?? 0,
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<RegisterSession>():
        Navigator.of(context).pop(true);
      case Error<RegisterSession>():
        setState(() {
          _isStarting = false;
          _failed = true;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return AdaptiveDialogSurface(
      size: AdaptiveModalSize.compact,
      child: AlertDialog(
        icon: const Icon(Icons.point_of_sale_outlined),
        title: Text(l10n.paymentDrawerTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.paymentDrawerMessage, style: theme.textTheme.bodySmall),
            if (_failed) ...[
              const SizedBox(height: 12),
              PointyInlineMessage.error(
                message: l10n.paymentDrawerStartError,
                icon: Icons.warning_amber_outlined,
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _openingCashController,
              enabled: !_isStarting,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
              onChanged: (_) {
                if (_showRequiredError) {
                  setState(() => _showRequiredError = false);
                }
              },
              onSubmitted: (_) => _isStarting ? null : _start(),
              decoration: InputDecoration(
                labelText: l10n.openingCashInputLabel,
                hintText: widget.requireOpeningCash
                    ? null
                    : l10n.moneyAmountHint,
                errorText: _showRequiredError
                    ? l10n.openingCashRequiredError
                    : null,
                prefixIcon: const Icon(Icons.payments_outlined),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _isStarting
                ? null
                : () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton.icon(
            onPressed: _isStarting ? null : _start,
            icon: _isStarting
                ? const SizedBox.square(
                    dimension: 18,
                    child: PointySpinner(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(
              _isStarting
                  ? l10n.startingRegisterSessionButton
                  : l10n.paymentDrawerConfirm,
            ),
          ),
        ],
      ),
    );
  }
}
