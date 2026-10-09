import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../view_models/pos_view_model.dart';
import 'service_texts.dart';

/// What the cashier decided about service lines that were priced again.
enum ServiceRequoteDecision {
  /// Take the new prices, and drop the lines the server no longer offers.
  accept,

  /// Leave the invoice exactly as it was.
  cancel,
}

/// Puts in front of the cashier what changed when service lines — airtime, a
/// bill — priced earlier were priced again: the old price and the new one, or
/// that the server no longer makes the offer. Nothing is changed until they
/// choose; closing the dialog any other way is [ServiceRequoteDecision.cancel].
Future<ServiceRequoteDecision> showServiceRequoteDialog(
  BuildContext context,
  List<ServiceRequote> changes,
) async {
  final decision = await showDialog<ServiceRequoteDecision>(
    context: context,
    builder: (dialogContext) => ServiceRequoteDialog(changes: changes),
  );
  return decision ?? ServiceRequoteDecision.cancel;
}

class ServiceRequoteDialog extends StatelessWidget {
  const ServiceRequoteDialog({super.key, required this.changes});

  final List<ServiceRequote> changes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final anyGone = changes.any((change) => change.isRefused);
    return AlertDialog(
      key: const ValueKey('service_requote_dialog'),
      icon: Icon(Icons.price_change_outlined, color: colors.warning, size: 40),
      title: Text(l10n.posServiceRequoteTitle, textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.posServiceRequoteBody,
                style: textTheme.bodyMedium?.copyWith(
                  color: colors.ink,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              for (final change in changes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          ltrIsolated(
                            change.line.integration?.subscriberRef ?? '',
                          ),
                          change.line.integration?.optionLabel ?? '',
                        ].where((part) => part.trim().isNotEmpty).join(' · '),
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (change.isRefused) ...[
                        Text(
                          l10n.posServiceRequoteGone,
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.danger,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          serviceRefusalText(
                            l10n,
                            change.refusal?.errorCode ?? '',
                            min: change.refusal?.min,
                            max: change.refusal?.max,
                          ),
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                      ] else
                        Text(
                          l10n.posServiceRequotePrice(
                            formatMoney(change.oldPrice),
                            formatMoney(change.newPrice ?? 0),
                          ),
                          key: const ValueKey('service_requote_price'),
                          style: PointyTypography.numeric(
                            (textTheme.titleMedium ?? const TextStyle())
                                .copyWith(
                                  color: colors.primaryStrong,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          key: const ValueKey('service_requote_cancel'),
          onPressed: () =>
              Navigator.of(context).pop(ServiceRequoteDecision.cancel),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          key: const ValueKey('service_requote_accept'),
          onPressed: () =>
              Navigator.of(context).pop(ServiceRequoteDecision.accept),
          child: Text(
            anyGone
                ? l10n.posServiceRequoteAcceptGone
                : l10n.posServiceRequoteAccept,
          ),
        ),
      ],
    );
  }
}

/// Shows what the server answered when it priced [changes] again, and does
/// what the cashier decides: take the new prices and drop the lines no longer
/// offered, or leave the invoice exactly as it was.
Future<void> resolveServiceRequotes(
  BuildContext context,
  PosViewModel viewModel,
  List<ServiceRequote> changes,
) async {
  final decision = await showServiceRequoteDialog(context, changes);
  if (decision != ServiceRequoteDecision.accept) {
    return;
  }
  for (final change in changes) {
    if (change.isRefused) {
      viewModel.dropServiceRequote(change);
    } else {
      viewModel.acceptServiceRequote(change);
    }
  }
}
