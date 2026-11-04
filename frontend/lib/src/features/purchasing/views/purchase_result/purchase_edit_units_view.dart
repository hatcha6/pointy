import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/purchase_edit_unit_choice.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/formatters.dart';
import 'purchase_result_buttons.dart';

/// A received order's serial line was lowered: which handsets never came?
///
/// The server lists the ones still on the shelf and will not pick for the
/// owner — each has its own number, and the wrong one would leave the books
/// naming a handset that is in the drawer. Sold ones are not offered at all.
class PurchaseEditUnitsView extends StatefulWidget {
  const PurchaseEditUnitsView({
    super.key,
    required this.choices,
    required this.onConfirm,
    required this.onBack,
  });

  final List<PurchaseEditUnitChoice> choices;
  final ValueChanged<List<int>> onConfirm;
  final VoidCallback onBack;

  @override
  State<PurchaseEditUnitsView> createState() => _PurchaseEditUnitsViewState();
}

class _PurchaseEditUnitsViewState extends State<PurchaseEditUnitsView> {
  final _picked = <int, Set<int>>{};

  Set<int> _pickedFor(PurchaseEditUnitChoice choice) =>
      _picked.putIfAbsent(choice.lineId, () => <int>{});

  bool get _complete => widget.choices.every(
    (choice) => _pickedFor(choice).length == choice.removeCount,
  );

  void _toggle(PurchaseEditUnitChoice choice, int unitId, bool on) {
    final picked = _pickedFor(choice);
    setState(() {
      if (!on) {
        picked.remove(unitId);
      } else if (picked.length < choice.removeCount) {
        picked.add(unitId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyResultPanel(
      key: const ValueKey('purchase_result_edit_units'),
      tone: PointyResultTone.attention,
      title: l10n.purchaseEditUnitsTitle,
      subtitle: l10n.purchaseEditUnitsSubtitle,
      footer: PurchaseResultButtons(
        primary: PurchaseResultButton(
          name: 'edit_units_confirm',
          label: l10n.purchaseEditUnitsConfirm,
          icon: Icons.check_rounded,
          onPressed: _complete
              ? () =>
                    widget.onConfirm([for (final ids in _picked.values) ...ids])
              : null,
        ),
        secondary: PurchaseResultButton(
          name: 'back',
          label: l10n.purchaseResultBackToDraft,
          icon: Icons.edit_note_rounded,
          onPressed: widget.onBack,
        ),
      ),
      children: [
        for (final choice in widget.choices)
          PointyResultSection(
            key: ValueKey('purchase_edit_units_line_${choice.lineId}'),
            title: l10n.purchaseEditUnitsPick(
              choice.removeCount,
              choice.productName,
            ),
            icon: Icons.qr_code_2_rounded,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final unit in choice.candidates)
                  CheckboxListTile(
                    key: ValueKey('purchase_edit_unit_${unit.id}'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _pickedFor(choice).contains(unit.id),
                    onChanged: (on) => _toggle(choice, unit.id, on ?? false),
                    title: Text(ltrIsolated(unit.code)),
                  ),
              ],
            ),
          ),
        PointyResultSection(
          title: l10n.checkoutResultWhatToDo,
          icon: Icons.lightbulb_outline_rounded,
          child: PointyResultTips(tips: [l10n.purchaseEditUnitsTip]),
        ),
      ],
    );
  }
}
