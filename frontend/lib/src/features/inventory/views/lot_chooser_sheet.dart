import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/missing_lot.dart';
import '../../../data/models/stock_batch.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/tracking/lot_state_badges.dart';
import '../../../shared/units.dart';

/// Which lot a pile of grandfathered units goes into: one this variant already
/// has, or a new one typed off the box.
///
/// One answer for the whole selection, because a lot is what the packs in
/// front of the person have in common — a different lot is a different pile.
/// Returns null when dismissed.
Future<LotChoice?> showLotChooserSheet(
  BuildContext context, {
  required String productLabel,
  required int count,
  required List<StockBatch> lots,
  bool expiryRequired = false,
}) {
  return showModalBottomSheet<LotChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => LotChooserBody(
      productLabel: productLabel,
      count: count,
      lots: lots,
      expiryRequired: expiryRequired,
      onChosen: (choice) => Navigator.of(context).pop(choice),
    ),
  );
}

/// The sheet's content, public so a preview or a test can render it in place.
class LotChooserBody extends StatefulWidget {
  const LotChooserBody({
    super.key,
    required this.productLabel,
    required this.count,
    required this.lots,
    required this.onChosen,
    this.expiryRequired = false,
  });

  final String productLabel;
  final int count;
  final List<StockBatch> lots;
  final bool expiryRequired;
  final ValueChanged<LotChoice> onChosen;

  @override
  State<LotChooserBody> createState() => _LotChooserBodyState();
}

class _LotChooserBodyState extends State<LotChooserBody> {
  final TextEditingController _code = TextEditingController();

  /// The chosen existing lot, or none.
  int? _batchId;

  /// The new-lot option is chosen. Nothing is chosen up front — a pile put
  /// into the wrong lot by an untouched default is a recall that misses it —
  /// unless there is nothing to choose from, and then it is already open.
  late bool _isNew = widget.lots.isEmpty;
  DateTime? _expiry;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  bool get _canConfirm {
    if (_batchId != null) {
      return true;
    }
    if (!_isNew) {
      return false;
    }
    return _code.text.trim().isNotEmpty &&
        (!widget.expiryRequired || _expiry != null);
  }

  void _confirm() {
    final batchId = _batchId;
    if (batchId != null) {
      final lot = widget.lots.firstWhere((lot) => lot.id == batchId);
      widget.onChosen(LotChoice.existing(batchId, label: lot.displayCode));
      return;
    }
    widget.onChosen(LotChoice.create(_code.text.trim(), expiryDate: _expiry));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return SafeArea(
      child: Padding(
        padding: spacing.pagePadding.copyWith(
          top: 0,
          bottom:
              spacing.pagePadding.bottom +
              MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointyDetailCallout(
              icon: Icons.inventory_2_outlined,
              title: l10n.lotChooserTitle,
              message: l10n.lotChooserSubtitle(
                widget.count,
                widget.productLabel,
              ),
            ),
            SizedBox(height: spacing.md),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  PointySectionHeader(title: l10n.lotChooserExisting),
                  if (widget.lots.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: spacing.sm),
                      child: Text(
                        l10n.lotChooserNoLots,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                      ),
                    ),
                  for (final lot in widget.lots)
                    _ChoiceTile(
                      key: ValueKey('lot_choice_${lot.id}'),
                      selected: _batchId == lot.id,
                      title: lot.displayCode.isEmpty
                          ? l10n.stockBatchNoCode
                          : lot.displayCode,
                      subtitle: [
                        lot.expiryDate == null
                            ? l10n.lotChooserNoExpiry
                            : l10n.lotChooserExpires(
                                formatDate(lot.expiryDate!),
                              ),
                        l10n.lotChooserOnHand(formatQuantity(lot.onHand)),
                      ].join(' • '),
                      badges: LotStateBadges(
                        isSellable: lot.isSellable,
                        status: lot.status,
                        expiryDate: lot.expiryDate,
                      ),
                      onTap: () => setState(() {
                        _batchId = lot.id;
                        _isNew = false;
                      }),
                    ),
                  const Divider(height: 24),
                  _ChoiceTile(
                    key: const ValueKey('lot_choice_new'),
                    selected: _isNew,
                    title: l10n.lotChooserNew,
                    icon: Icons.add_circle_outline,
                    onTap: () => setState(() {
                      _batchId = null;
                      _isNew = true;
                    }),
                  ),
                  if (_isNew) ...[
                    SizedBox(height: spacing.sm),
                    _NewLotFields(
                      code: _code,
                      expiry: _expiry,
                      expiryRequired: widget.expiryRequired,
                      onCodeChanged: () => setState(() {}),
                      onExpiryChanged: (date) => setState(() => _expiry = date),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(height: spacing.md),
            FilledButton.icon(
              key: const ValueKey('lot_chooser_confirm'),
              onPressed: _canConfirm ? _confirm : null,
              icon: const Icon(Icons.check),
              label: Text(l10n.lotChooserConfirm(widget.count)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A selectable row: a filled ring when chosen, the lot's facts beneath.
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    super.key,
    required this.selected,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.badges,
    this.icon,
  });

  final bool selected;
  final String title;
  final String? subtitle;
  final LotStateBadges? badges;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsetsDirectional.only(start: 4, end: 4),
      selected: selected,
      selectedColor: colors.primaryStrong,
      leading: Icon(
        selected
            ? Icons.radio_button_checked
            : (icon ?? Icons.radio_button_unchecked),
        color: selected ? colors.primaryStrong : colors.mutedInk,
      ),
      title: Text(
        title,
        style: PointyTypography.numeric(
          Theme.of(context).textTheme.bodyLarge ?? const TextStyle(),
        ),
      ),
      // The lot's stop-sale under its facts, not squeezed beside them: a
      // recalled lot is still a valid answer, and it has to read as one.
      subtitle: subtitle == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(subtitle!),
                if (badges case final badges? when badges.isStopped) ...[
                  const SizedBox(height: 4),
                  badges,
                ],
              ],
            ),
      onTap: onTap,
    );
  }
}

class _NewLotFields extends StatelessWidget {
  const _NewLotFields({
    required this.code,
    required this.expiry,
    required this.expiryRequired,
    required this.onCodeChanged,
    required this.onExpiryChanged,
  });

  final TextEditingController code;
  final DateTime? expiry;
  final bool expiryRequired;
  final VoidCallback onCodeChanged;
  final ValueChanged<DateTime?> onExpiryChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final missingDate = expiryRequired && expiry == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScanWedgeTarget(
          child: TextField(
            key: const ValueKey('lot_chooser_code'),
            controller: code,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.batchCaptureLotCode,
              prefixIcon: const Icon(Icons.tag),
            ),
            onChanged: (_) => onCodeChanged(),
          ),
        ),
        const SizedBox(height: 10),
        InkWell(
          key: const ValueKey('lot_chooser_expiry'),
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: expiry ?? now,
              firstDate: DateTime(now.year - 5),
              lastDate: DateTime(now.year + 20),
            );
            if (picked != null) {
              onExpiryChanged(picked);
            }
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: l10n.batchCaptureExpiry,
              prefixIcon: const Icon(Icons.event_outlined),
              errorText: missingDate ? l10n.lotChooserExpiryNeeded : null,
            ),
            child: Text(
              expiry == null ? '—' : formatDate(expiry!),
              style: PointyTypography.numeric(
                Theme.of(context).textTheme.bodyLarge ?? const TextStyle(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // The horizons a receiver reading a foil edge types all day.
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final months in const [6, 12, 24, 36])
              OutlinedButton(
                onPressed: () => onExpiryChanged(_endOfMonthIn(months)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 34),
                  foregroundColor: colors.ink,
                ),
                child: Text(l10n.batchCaptureExpiryShortcut(months)),
              ),
          ],
        ),
      ],
    );
  }

  /// The last day of the month [months] from now: a pack expires in a month,
  /// and the day on the foil is the last one.
  static DateTime _endOfMonthIn(int months) {
    final now = DateTime.now();
    final month = now.month + months;
    final year = now.year + (month - 1) ~/ 12;
    final normalized = (month - 1) % 12 + 1;
    return DateTime(year, normalized + 1, 0);
  }
}
