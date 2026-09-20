import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_provider.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/integrations_view_model.dart';
import 'integration_presentation.dart';

/// The provider float: what is in it, and putting more in.
Future<bool?> showIntegrationFloatSheet({
  required BuildContext context,
  required IntegrationProviderKey providerKey,
  required IntegrationsViewModel viewModel,
}) {
  final l10n = AppLocalizations.of(context)!;
  viewModel.loadFloat(providerKey);
  return showAdaptiveFormSurface<bool>(
    context: context,
    title:
        '${l10n.integrationFloatTitle} · ${integrationProviderName(providerKey, l10n)}',
    builder: (sheetContext) =>
        IntegrationFloatForm(viewModel: viewModel, providerKey: providerKey),
  );
}

/// Four figures that are deliberately different things, and a way to add to
/// the first.
///
/// A top-up is **not** an expense — the money moved from the shop's cash box
/// to the provider and is still the shop's. It becomes cost when a recharge
/// is actually performed, and that cost already rides on the sale that sold
/// it. The explainer says so, because "I paid HD Box 1000, why isn't it in my
/// expenses" is the first question this screen will be asked.
class IntegrationFloatForm extends StatefulWidget {
  const IntegrationFloatForm({
    super.key,
    required this.viewModel,
    required this.providerKey,
  });

  final IntegrationsViewModel viewModel;
  final IntegrationProviderKey providerKey;

  @override
  State<IntegrationFloatForm> createState() => _IntegrationFloatFormState();
}

class _IntegrationFloatFormState extends State<IntegrationFloatForm> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reference = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    final ok = await widget.viewModel.recordTopUp(
      widget.providerKey,
      amount: amount,
      reference: _reference.text.trim(),
    );
    if (!mounted || !ok) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        final viewModel = widget.viewModel;
        if (viewModel.isLoadingFloat) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: PointyLoadingArea(),
          );
        }
        final float = viewModel.providerFloat;

        return Form(
          key: _formKey,
          child: Padding(
            padding: EdgeInsets.all(spacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (float != null) ...[
                  if (float.hasDrift) ...[
                    PointyInlineMessage.warning(
                      message: float.isShort
                          ? l10n.integrationFloatDriftShort(
                              formatMoney(float.drift!.abs()),
                            )
                          : l10n.integrationFloatDriftOver(
                              formatMoney(float.drift!.abs()),
                            ),
                      compact: true,
                    ),
                    SizedBox(height: spacing.sm),
                  ],
                  PointySummaryList(
                    rows: [
                      PointySummaryRow(
                        label: l10n.integrationFloatExpected,
                        value: formatMoney(float.expectedBalance),
                        emphasized: true,
                      ),
                      if (float.reportedBalance != null)
                        PointySummaryRow(
                          label: l10n.integrationFloatReported,
                          value: formatMoney(float.reportedBalance!),
                        ),
                      PointySummaryRow(
                        label: l10n.integrationFloatToppedUp,
                        value: formatMoney(float.toppedUp),
                      ),
                      PointySummaryRow(
                        label: l10n.integrationFloatDrawn,
                        value: formatMoney(float.drawn),
                      ),
                      if (float.committed > 0)
                        PointySummaryRow(
                          label: l10n.integrationFloatCommitted,
                          value: formatMoney(float.committed),
                        ),
                    ],
                  ),
                  SizedBox(height: spacing.sm),
                ],
                Text(
                  l10n.integrationFloatExplainer,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.pointyColors.mutedInk,
                  ),
                ),
                SizedBox(height: spacing.md),
                Text(
                  l10n.integrationTopUpTitle,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                SizedBox(height: spacing.sm),
                TextFormField(
                  controller: _amount,
                  textDirection: TextDirection.ltr,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: InputDecoration(
                    labelText: l10n.integrationTopUpAmount,
                    prefixIcon: const Icon(Icons.payments_outlined),
                  ),
                  validator: (value) {
                    final parsed = double.tryParse((value ?? '').trim());
                    return (parsed == null || parsed <= 0)
                        ? l10n.integrationTopUpAmountRequired
                        : null;
                  },
                ),
                SizedBox(height: spacing.sm),
                TextFormField(
                  controller: _reference,
                  decoration: InputDecoration(
                    labelText: l10n.integrationTopUpReference,
                    prefixIcon: const Icon(Icons.receipt_long_outlined),
                  ),
                ),
                SizedBox(height: spacing.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: viewModel.isSavingTopUp
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: Text(l10n.integrationCancel),
                    ),
                    SizedBox(width: spacing.sm),
                    FilledButton.icon(
                      onPressed: viewModel.isSavingTopUp ? null : _save,
                      icon: viewModel.isSavingTopUp
                          ? const SizedBox.square(
                              dimension: 16,
                              child: PointySpinner(strokeWidth: 2),
                            )
                          : const Icon(Icons.add),
                      label: Text(l10n.integrationTopUpSave),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
