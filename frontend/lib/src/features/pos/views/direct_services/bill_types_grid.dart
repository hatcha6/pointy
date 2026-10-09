import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/design/design.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../view_models/services_explainer_controller.dart';
import 'bill_flow_sheet.dart';
import 'pos_service_card.dart';
import 'service_card_layout.dart';
import 'service_test_mode_banner.dart';
import 'service_timeline.dart';
import 'services_strip.dart';

/// The key the bills explainer is remembered under.
const String billsExplainerKey = 'bills';

/// The «دفع الفواتير» tab: one card for each type of bill the shop can pay —
/// electricity, water, television, internet — on the same footing as the
/// brands. Tapping one opens that type's flow.
///
/// With [explainers] it greets a cashier who has never been here with what the
/// tab does, the way airtime does; once hidden, a «كيف يعمل؟» link is left.
class BillTypesGrid extends StatelessWidget {
  const BillTypesGrid({
    super.key,
    required this.entries,
    this.explainers,
    this.testMode = false,
  });

  final List<ServiceStripEntry> entries;
  final ServicesExplainerController? explainers;

  /// The relay is buying from its test supplier: said over the cards.
  final bool testMode;

  Future<void> _showHow(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return showBillHowSheet(
      context,
      title: l10n.posBillsHowTitle,
      electricityToken: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final explainers = this.explainers;
    if (explainers == null) {
      return _grid(context, showBanner: false);
    }
    return ListenableBuilder(
      listenable: explainers,
      builder: (context, _) =>
          _grid(context, showBanner: explainers.isShown(billsExplainerKey)),
    );
  }

  Widget _grid(BuildContext context, {required bool showBanner}) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const inset = 6.0;
        final layout = ServiceCardLayout.forWidth(
          constraints.maxWidth - inset * 2,
          spacing,
        );
        final extent = PosServiceCard.extentFor(
          layout.tileWidth,
          scaler: MediaQuery.textScalerOf(context),
        );
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            inset,
            spacing.sm + inset,
            inset,
            spacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (testMode) ...[
                const ServiceTestModeBanner(),
                SizedBox(height: spacing.md),
              ],
              if (showBanner) ...[
                ServiceExplainerBanner(
                  key: const ValueKey('bills_explainer'),
                  icon: Icons.receipt_long_rounded,
                  body: l10n.posBillsExplainerBody,
                  onHow: () => _showHow(context),
                  onDismiss: () => explainers?.dismiss(billsExplainerKey),
                ),
                SizedBox(height: spacing.md),
              ],
              Row(
                children: [
                  Icon(
                    Icons.receipt_long_rounded,
                    size: 20,
                    color: colors.primaryStrong,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.posServicesBillsIntro,
                      style: textTheme.titleSmall?.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (explainers != null && !showBanner)
                    TextButton.icon(
                      key: const ValueKey('bills_help'),
                      onPressed: () => _showHow(context),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.help_outline_rounded, size: 17),
                      label: Text(l10n.posServicesHow),
                    ),
                ],
              ),
              SizedBox(height: spacing.md),
              Wrap(
                spacing: layout.gap,
                runSpacing: spacing.md,
                children: [
                  for (final entry in entries)
                    SizedBox(
                      width: layout.tileWidth,
                      height: extent,
                      child: PosServiceCard(
                        key: ValueKey('bill_card_${entry.kind.name}'),
                        kind: entry.kind,
                        countries: entry.countries,
                        providers: entry.providers,
                        onTap: entry.onTap,
                        showsNewBadge: entry.isNew,
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
