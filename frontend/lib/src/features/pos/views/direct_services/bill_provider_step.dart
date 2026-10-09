import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/service_country_detail.dart';
import '../../../../data/models/service_kinds.dart';
import '../../../../shared/barcode/barcode_scan_listener.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../direct_services/arabic_search_text.dart';
import '../../view_models/bill_flow_view_model.dart';

/// Step two of a bill: the country's providers of this type, by their Arabic
/// names. Electricity is told apart by how it is paid — a prepaid meter that
/// gives a token, or a postpaid bill settled against an invoice — the others
/// are simply listed by company.
class BillProviderStep extends StatefulWidget {
  const BillProviderStep({super.key, required this.viewModel});

  final BillFlowViewModel viewModel;

  @override
  State<BillProviderStep> createState() => _BillProviderStepState();
}

class _BillProviderStepState extends State<BillProviderStep> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(BillBiller biller, String query) {
    if (query.isEmpty) {
      return true;
    }
    return normalizeSearchText(biller.name).contains(query) ||
        normalizeSearchText(biller.nameEn).contains(query);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final vm = widget.viewModel;
    if (vm.hasCountryError) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: PointyInlineMessage.error(
          message: l10n.posAirtimeCountryFailed,
          trailing: TextButton(
            onPressed: vm.retryCountry,
            child: Text(l10n.retryButton),
          ),
        ),
      );
    }
    if (vm.detail == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(child: PointySpinner()),
      );
    }
    final all = vm.billers;
    final query = normalizeSearchText(_search.text);
    final shown = [
      for (final biller in all)
        if (_matches(biller, query)) biller,
    ];
    final groups = vm.type == BillType.electricity;
    final prepaid = [
      for (final biller in shown)
        if (!groups || !biller.isPostpaid) biller,
    ];
    final postpaid = [
      for (final biller in shown)
        if (groups && biller.isPostpaid) biller,
    ];

    Widget section(String? title, List<BillBiller> billers) {
      if (billers.isEmpty) {
        return const SizedBox.shrink();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 6),
              child: Row(
                children: [
                  Icon(
                    title == l10n.posBillGroupPrepaid
                        ? Icons.electric_meter_rounded
                        : Icons.description_outlined,
                    size: 18,
                    color: colors.primaryStrong,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: textTheme.labelLarge?.copyWith(
                        color: colors.primaryDark,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          for (final biller in billers)
            _ProviderRow(
              key: ValueKey('bill_provider_${biller.id}'),
              biller: biller,
              type: vm.type,
              onTap: () => vm.selectBiller(biller),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (vm.isCountryFixed && vm.country != null) ...[
          PointyInlineMessage(
            key: const ValueKey('bill_limited_country'),
            message: l10n.posBillLimitedCountry(vm.country!.label),
            compact: true,
          ),
          const SizedBox(height: 10),
        ],
        if (all.length > 8) ...[
          ScanWedgeTarget(
            child: TextField(
              key: const ValueKey('bill_provider_search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                hintText: l10n.posBillProviderSearch,
                prefixIcon: const Icon(Icons.search_rounded),
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
        if (all.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                l10n.posBillProvidersNone,
                style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
              ),
            ),
          )
        else if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                l10n.posBillProviderNoResults,
                style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
              ),
            ),
          )
        else ...[
          section(groups ? l10n.posBillGroupPrepaid : null, prepaid),
          section(groups ? l10n.posBillGroupPostpaid : null, postpaid),
        ],
      ],
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    super.key,
    required this.biller,
    required this.type,
    required this.onTap,
  });

  final BillBiller biller;
  final BillType type;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final note = biller.requiresInvoice
        ? l10n.posBillProviderNeedsInvoice
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PointyRadii.input),
          side: BorderSide(color: colors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    _icon(type),
                    size: 22,
                    color: colors.primaryStrong,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        biller.label,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colors.ink,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                        ),
                      ),
                      if (note != null)
                        Text(
                          note,
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: colors.mutedInk),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _icon(BillType type) => switch (type) {
    BillType.electricity => Icons.bolt_rounded,
    BillType.water => Icons.water_drop_rounded,
    BillType.tv => Icons.tv_rounded,
    BillType.internet => Icons.wifi_rounded,
    _ => Icons.receipt_long_rounded,
  };
}
