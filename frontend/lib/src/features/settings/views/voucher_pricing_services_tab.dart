import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/voucher_pricing.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../view_models/voucher_pricing_view_model.dart';

/// The services tab: the shop-wide default, then one row per direct service
/// with its mode, its markup and a live example.
class VoucherPricingServicesTab extends StatelessWidget {
  const VoucherPricingServicesTab({super.key, required this.viewModel});

  final VoucherPricingViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final vm = viewModel;
    final pricing = vm.pricing;
    if (pricing == null) {
      if (vm.loadFailed) {
        return PointyErrorState(
          title: l10n.voucherPricingLoadError,
          icon: Icons.cloud_off_outlined,
          action: FilledButton.icon(
            onPressed: vm.loadPricing,
            icon: const Icon(Icons.sync),
            label: Text(l10n.retryButton),
          ),
        );
      }
      return const PointyLoadingArea();
    }
    final rule = pricing.companyRule;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _Panel(
                    key: const ValueKey('pricing_default'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l10n.voucherPricingDefaultTitle,
                          style: textTheme.titleMedium?.copyWith(
                            color: colors.ink,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.voucherPricingDefaultHint,
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _ModeRow(
                          keyPrefix: 'pricing_default',
                          mode: pricing.defaultMode,
                          markup: pricing.defaultMarkupPercent,
                          onMode: vm.setDefaultMode,
                          onMarkup: vm.setDefaultMarkup,
                        ),
                        if (rule.fixedLyd != null &&
                            rule.shopSharePercent != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            l10n.voucherPricingRuleHint(
                              formatMoney(rule.fixedLyd!),
                              _percent(rule.shopSharePercent!),
                            ),
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.mutedInk,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.voucherPricingServicesTitle,
                    style: textTheme.titleSmall?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final service in pricing.services) ...[
                    _ServiceRow(service: service, viewModel: vm),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
        ),
        _SaveBar(viewModel: vm),
      ],
    );
  }
}

String _percent(double value) =>
    value == value.roundToDouble() ? '${value.round()}' : '$value';

class _Panel extends StatelessWidget {
  const _Panel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: colors.line),
      ),
      child: child,
    );
  }
}

/// «سعر الشركة | سعري أنا» and, for the second, the markup field.
class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.keyPrefix,
    required this.mode,
    required this.markup,
    required this.onMode,
    required this.onMarkup,
  });

  final String keyPrefix;
  final PricingMode mode;
  final double? markup;
  final ValueChanged<PricingMode> onMode;
  final ValueChanged<double?> onMarkup;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final custom = mode == PricingMode.custom;
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<PricingMode>(
          key: ValueKey('${keyPrefix}_mode'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: PricingMode.company,
              label: Text(l10n.voucherPricingModeCompany),
            ),
            ButtonSegment(
              value: PricingMode.custom,
              label: Text(l10n.voucherPricingModeCustom),
            ),
          ],
          selected: {mode},
          onSelectionChanged: (set) => onMode(set.first),
        ),
        if (custom)
          SizedBox(
            width: 132,
            child: _PercentField(
              key: ValueKey('${keyPrefix}_markup'),
              initial: markup,
              label: l10n.voucherPricingMarkupLabel,
              onChanged: onMarkup,
            ),
          ),
      ],
    );
  }
}

class _PercentField extends StatefulWidget {
  const _PercentField({
    super.key,
    required this.initial,
    required this.label,
    required this.onChanged,
  });

  final double? initial;
  final String label;
  final ValueChanged<double?> onChanged;

  @override
  State<_PercentField> createState() => _PercentFieldState();
}

class _PercentFieldState extends State<_PercentField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial == null ? '' : _percent(widget.initial!),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
    decoration: InputDecoration(labelText: widget.label, isDense: true),
    onChanged: (text) => widget.onChanged(double.tryParse(text)),
  );
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({required this.service, required this.viewModel});

  final PricingService service;
  final VoucherPricingViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final id =
        '${service.key}${service.country == null ? '' : '_${service.country}'}';
    final example = service.example;
    final yours = service.mode == PricingMode.custom
        ? markupExample(example.shopPays, service.markupPercent) ??
              example.yourPrice
        : example.companyPrice;
    final showExample = example.shopPays != null && yours != null;
    return _Panel(
      key: ValueKey('pricing_service_$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  service.label.isEmpty ? service.key : service.label,
                  style: textTheme.titleSmall?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (service.country != null)
                Text(
                  service.country!,
                  textDirection: TextDirection.ltr,
                  style: textTheme.labelMedium?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _ModeRow(
            keyPrefix: 'pricing_service_$id',
            mode: service.mode,
            markup: service.markupPercent,
            onMode: (mode) => viewModel.setServiceMode(service, mode),
            onMarkup: (value) => viewModel.setServiceMarkup(service, value),
          ),
          if (showExample) ...[
            const SizedBox(height: 8),
            Text(
              l10n.voucherPricingExample(
                formatMoney(example.shopPays!),
                formatMoney(example.companyPrice ?? example.shopPays!),
                formatMoney(yours),
              ),
              key: ValueKey('pricing_example_$id'),
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ],
        ],
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({required this.viewModel});

  final VoucherPricingViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final vm = viewModel;
    final error = vm.saveError;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (error != null) ...[
                    PointyInlineMessage.error(
                      key: const ValueKey('pricing_save_error'),
                      message: error.isEmpty
                          ? l10n.voucherPricingSaveFailed
                          : error,
                      icon: Icons.error_outline_rounded,
                      compact: true,
                    ),
                    const SizedBox(height: 8),
                  ] else if (vm.justSaved) ...[
                    Text(
                      l10n.voucherPricingSaved,
                      key: const ValueKey('pricing_saved'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.primaryDark,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  SizedBox(
                    height: 46,
                    child: FilledButton(
                      key: const ValueKey('pricing_save'),
                      onPressed: vm.isDirty && !vm.isSaving
                          ? vm.savePricing
                          : null,
                      child: Text(l10n.voucherPricingSave),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
