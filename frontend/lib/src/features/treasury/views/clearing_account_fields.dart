import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/money_position.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/weekday_labels.dart';
import 'treasury_ui.dart';

/// When a processor closes its day. Midnight for Moamalat; the others cover
/// processors that close early or late.
const clearingCutoffChoices = [
  '00:00:00',
  '22:00:00',
  '23:00:00',
  '01:00:00',
  '02:00:00',
];

/// The fields only a clearing account has: which bank the processor pays
/// into, the first day it holds, and the processor's schedule.
///
/// The bank is fixed once the account exists — which card sales it holds is a
/// rule about that bank — so on an edit it is shown, not offered.
class ClearingAccountFields extends StatelessWidget {
  const ClearingAccountFields({
    super.key,
    required this.isNew,
    required this.banks,
    required this.settlesIntoId,
    required this.onSettlesIntoChanged,
    required this.startsOn,
    required this.onStartsOnChanged,
    required this.cutoff,
    required this.onCutoffChanged,
    required this.weekdays,
    required this.onWeekdaysChanged,
    required this.lagDays,
    required this.onLagDaysChanged,
    this.settlesIntoName = '',
  });

  final bool isNew;
  final List<MoneyAccount> banks;
  final int? settlesIntoId;
  final String settlesIntoName;
  final ValueChanged<int?> onSettlesIntoChanged;
  final DateTime startsOn;
  final ValueChanged<DateTime> onStartsOnChanged;
  final String cutoff;
  final ValueChanged<String> onCutoffChanged;
  final Set<int> weekdays;
  final ValueChanged<Set<int>> onWeekdaysChanged;
  final int lagDays;
  final ValueChanged<int> onLagDaysChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailCallout(
          icon: Icons.hourglass_bottom_outlined,
          tone: PointyCalloutTone.neutral,
          title: l10n.treasuryClearingIntro,
        ),
        SizedBox(height: spacing.sm),
        if (isNew && banks.isEmpty)
          PointyInlineMessage.error(message: l10n.treasuryClearingNoBank)
        else if (isNew)
          DropdownButtonFormField<int>(
            key: const ValueKey('money_account_settles_into_field'),
            initialValue: settlesIntoId,
            decoration: InputDecoration(
              labelText: l10n.treasuryClearingSettlesIntoLabel,
            ),
            items: [
              for (final bank in banks)
                DropdownMenuItem(value: bank.id, child: Text(bank.name)),
            ],
            onChanged: onSettlesIntoChanged,
            validator: (value) =>
                value == null ? l10n.treasuryClearingBankRequired : null,
          )
        else
          InputDecorator(
            decoration: InputDecoration(
              labelText: l10n.treasuryClearingSettlesIntoLabel,
              prefixIcon: const Icon(Icons.account_balance_outlined),
            ),
            child: Text(settlesIntoName),
          ),
        SizedBox(height: spacing.sm),
        _StartDayField(value: startsOn, onChanged: onStartsOnChanged),
        SizedBox(height: spacing.sm),
        DropdownButtonFormField<String>(
          key: const ValueKey('money_account_cutoff_field'),
          initialValue: clearingCutoffChoices.contains(cutoff)
              ? cutoff
              : clearingCutoffChoices.first,
          decoration: InputDecoration(
            labelText: l10n.treasuryClearingCutoffLabel,
          ),
          items: [
            for (final choice in clearingCutoffChoices)
              DropdownMenuItem(
                value: choice,
                child: Text(
                  choice == '00:00:00'
                      ? l10n.treasuryClearingCutoffMidnight
                      : choice.substring(0, 5),
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              onCutoffChanged(value);
            }
          },
        ),
        SizedBox(height: spacing.sm),
        InputDecorator(
          decoration: InputDecoration(
            labelText: l10n.treasuryClearingWeekdaysLabel,
            errorText: weekdays.isEmpty
                ? l10n.treasuryClearingWeekdaysRequired
                : null,
          ),
          child: Wrap(
            spacing: spacing.xs,
            runSpacing: spacing.xs,
            children: [
              for (final weekday in weekdaysSaturdayFirst)
                FilterChip(
                  key: ValueKey('money_account_weekday_$weekday'),
                  label: Text(weekdayLabel(l10n, weekday)),
                  selected: weekdays.contains(weekday),
                  onSelected: (selected) => onWeekdaysChanged(
                    selected
                        ? {...weekdays, weekday}
                        : ({...weekdays}..remove(weekday)),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(height: spacing.sm),
        DropdownButtonFormField<int>(
          key: const ValueKey('money_account_lag_field'),
          initialValue: lagDays.clamp(1, 3),
          decoration: InputDecoration(labelText: l10n.treasuryClearingLagLabel),
          items: [
            for (final days in const [1, 2, 3])
              DropdownMenuItem(
                value: days,
                child: Text(l10n.treasuryClearingLagDays(days)),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              onLagDaysChanged(value);
            }
          },
        ),
      ],
    );
  }
}

/// The first processor day the account holds: today, or the oldest day the
/// processor has not paid yet — never the future, never more than a month ago.
class _StartDayField extends StatelessWidget {
  const _StartDayField({required this.value, required this.onChanged});

  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InkWell(
      key: const ValueKey('money_account_clearing_start_field'),
      onTap: () async {
        final today = DateTime.now();
        final first = today.subtract(const Duration(days: 31));
        final picked = await showDatePicker(
          context: context,
          initialDate: value.isBefore(first) ? first : value,
          firstDate: first,
          lastDate: today,
        );
        if (picked != null) {
          onChanged(DateTime(picked.year, picked.month, picked.day));
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: l10n.treasuryClearingStartLabel,
          helperText: l10n.treasuryClearingStartHelper,
          helperMaxLines: 2,
          prefixIcon: const Icon(Icons.event_outlined),
          suffixIcon: const Icon(Icons.expand_more),
        ),
        child: Text(
          treasuryDayLabel(l10n, value),
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}
