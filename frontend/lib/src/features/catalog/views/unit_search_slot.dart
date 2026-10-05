import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_unit.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../view_models/unit_search_lookup.dart';
import 'unit_search_match_card.dart';

/// The place above the product results where an identifier's article shows.
///
/// Takes the gap that was already there between the search bar and the list,
/// and nothing more until something answers: while the lookup runs, a hairline
/// of progress inside that gap; when it finds nothing, the gap as it always
/// was. So a shop typing barcodes all day never sees the list jump. Only a
/// match grows the slot, with the same short motion as any other state change.
class UnitSearchSlot extends StatelessWidget {
  const UnitSearchSlot({
    super.key,
    required this.lookup,
    required this.gap,
    required this.onOpenUnit,
    this.onOpenInvoice,
    this.onOpenCustomer,
  });

  final UnitSearchLookup lookup;

  /// The list's own spacing above the results, which the slot occupies.
  final double gap;
  final ValueChanged<StockUnit> onOpenUnit;
  final ValueChanged<int>? onOpenInvoice;
  final ValueChanged<int>? onOpenCustomer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return ListenableBuilder(
      listenable: lookup,
      builder: (context, _) {
        final match = lookup.match;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: gap,
              child: lookup.isLoading
                  ? Center(
                      child: PointyProgressBar(
                        key: const ValueKey('unit_search_progress'),
                        minHeight: 2,
                        color: colors.primaryStrong,
                        backgroundColor: colors.line,
                        semanticsLabel: l10n.unitSearchLookingUp,
                      ),
                    )
                  : null,
            ),
            AnimatedSize(
              duration: PointyMotion.standard,
              curve: PointyMotion.curve,
              alignment: AlignmentDirectional.topCenter,
              child: match == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: EdgeInsets.only(bottom: gap),
                      child: UnitSearchMatchCard(
                        lookup: match,
                        typedCode: lookup.code,
                        onOpenUnit: onOpenUnit,
                        onOpenInvoice: onOpenInvoice,
                        onOpenCustomer: onOpenCustomer,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
