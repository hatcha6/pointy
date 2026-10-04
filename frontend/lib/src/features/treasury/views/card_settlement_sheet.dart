import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/card_settlement.dart';
import '../../../data/models/money_position.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/card_settlement_view_model.dart';
import '../view_models/money_position_view_model.dart';
import 'held_day_tile.dart';
import 'treasury_ui.dart';

/// "The processor's transfer reached the bank" — the one action a clearing
/// account exists for.
///
/// The owner types the amount from the bank's SMS; the days it most likely
/// paid are ticked for them, the difference from the estimated fee is shown in
/// a sentence, and nothing is stored until they confirm. Returns the recorded
/// settlement, or null when the sheet was dismissed.
Future<CardSettlement?> showCardSettlementSheet(
  BuildContext context, {
  required MoneyPositionViewModel viewModel,
  required MoneyAccount account,
}) {
  return showAdaptiveFormSurface<CardSettlement>(
    context: context,
    size: AdaptiveModalSize.expanded,
    builder: (sheetContext) =>
        _CardSettlementSheet(positionViewModel: viewModel, account: account),
  );
}

/// Opens the settlement sheet for the shop's clearing account — or, for the
/// rare shop with two processors, asks which one paid first.
Future<void> recordCardSettlementFor(
  BuildContext context, {
  required MoneyPositionViewModel viewModel,
  required List<MoneyAccount> accounts,
}) async {
  if (accounts.isEmpty) {
    return;
  }
  var account = accounts.first;
  if (accounts.length > 1) {
    final chosen = await showModalBottomSheet<MoneyAccount>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final candidate in accounts)
              ListTile(
                leading: Icon(treasuryAccountIcon(candidate)),
                title: Text(candidate.name),
                subtitle: candidate.settlesIntoName.isEmpty
                    ? null
                    : Text(candidate.settlesIntoName),
                onTap: () => Navigator.of(sheetContext).pop(candidate),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) {
      return;
    }
    account = chosen;
  }
  if (!context.mounted) {
    return;
  }
  await showCardSettlementSheet(
    context,
    viewModel: viewModel,
    account: account,
  );
}

class _CardSettlementSheet extends StatefulWidget {
  const _CardSettlementSheet({
    required this.positionViewModel,
    required this.account,
  });

  final MoneyPositionViewModel positionViewModel;
  final MoneyAccount account;

  @override
  State<_CardSettlementSheet> createState() => _CardSettlementSheetState();
}

class _CardSettlementSheetState extends State<_CardSettlementSheet> {
  late final CardSettlementViewModel _viewModel;
  final _amountController = TextEditingController();
  final _referenceController = TextEditingController();
  final _noteController = TextEditingController();
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _viewModel = CardSettlementViewModel(
      widget.positionViewModel.repository,
      account: widget.account,
    )..load();
  }

  @override
  void dispose() {
    _viewModel.dispose();
    _amountController.dispose();
    _referenceController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _viewModel.settledOn,
      firstDate: today.subtract(const Duration(days: 90)),
      lastDate: today,
    );
    if (picked != null) {
      _viewModel.setSettledOn(picked);
    }
  }

  void _toggleExpanded(HeldDay day) {
    setState(() {
      if (!_expanded.remove(day.key)) {
        _expanded.add(day.key);
        _viewModel.loadPayments(day);
      }
    });
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final settlement = await _viewModel.submit(
      reference: _referenceController.text,
      note: _noteController.text,
    );
    if (settlement == null || !mounted) {
      return;
    }
    // The balances moved between two accounts; the screen behind this sheet
    // must show the server's figures, not a guess.
    await widget.positionViewModel.load();
    navigator.pop(settlement);
    messenger.showSnackBar(SnackBar(content: Text(l10n.cardSettlementSaved)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final colors = context.pointyColors;

    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final vm = _viewModel;
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.all(spacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PointySectionHeader(title: l10n.cardSettlementTitle),
                Text(
                  l10n.cardSettlementSubtitle(
                    widget.account.name,
                    widget.account.settlesIntoName,
                  ),
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
                SizedBox(height: spacing.md),
                TextField(
                  key: const ValueKey('card_settlement_amount_field'),
                  controller: _amountController,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    // Western and Arabic-Indic digits alike: the keyboard on
                    // an Arabic phone types the latter.
                    FilteringTextInputFormatter.allow(
                      RegExp(r'[0-9٠-٩۰-۹.,٫]'),
                    ),
                  ],
                  onChanged: vm.setAmountText,
                  decoration: InputDecoration(
                    labelText: l10n.cardSettlementAmountLabel,
                    helperText: l10n.cardSettlementAmountHelper,
                  ),
                ),
                SizedBox(height: spacing.sm),
                InkWell(
                  key: const ValueKey('card_settlement_date_field'),
                  onTap: _pickDate,
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l10n.cardSettlementDateLabel,
                      prefixIcon: const Icon(Icons.event_outlined),
                      suffixIcon: const Icon(Icons.expand_more),
                    ),
                    child: Text(
                      treasuryDayLabel(l10n, vm.settledOn),
                      style: textTheme.bodyLarge,
                    ),
                  ),
                ),
                SizedBox(height: spacing.md),
                if (vm.amountCents != null && vm.takings != null) ...[
                  _MatchBanner(match: vm.match),
                  SizedBox(height: spacing.md),
                ],
                PointySectionHeader(title: l10n.cardSettlementDaysTitle),
                SizedBox(height: spacing.sm),
                ..._days(context, l10n),
                SizedBox(height: spacing.md),
                _Summary(viewModel: vm),
                SizedBox(height: spacing.md),
                TextField(
                  key: const ValueKey('card_settlement_reference_field'),
                  controller: _referenceController,
                  decoration: InputDecoration(
                    labelText: l10n.cardSettlementReferenceLabel,
                  ),
                ),
                SizedBox(height: spacing.sm),
                TextField(
                  controller: _noteController,
                  decoration: InputDecoration(
                    labelText: l10n.cardSettlementNoteLabel,
                  ),
                ),
                if (vm.failure != null) ...[
                  SizedBox(height: spacing.md),
                  PointyInlineMessage.error(
                    message: switch (vm.failure!) {
                      CardSettlementFailure.explained =>
                        vm.failureMessage ?? l10n.cardSettlementFailed,
                      CardSettlementFailure.forbidden =>
                        l10n.cardSettlementForbidden,
                      CardSettlementFailure.generic =>
                        l10n.cardSettlementFailed,
                    },
                  ),
                ],
                SizedBox(height: spacing.md),
                FilledButton.icon(
                  key: const ValueKey('card_settlement_submit_button'),
                  onPressed: vm.canSubmit ? _submit : null,
                  icon: vm.isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(l10n.cardSettlementSubmit),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _days(BuildContext context, AppLocalizations l10n) {
    final vm = _viewModel;
    final spacing = AdaptiveSpacing.of(context);
    if (vm.takings == null && vm.isLoading) {
      return [
        PointySkeleton(
          child: Column(
            children: [
              for (var i = 0; i < 3; i++) ...[
                const PointySkeletonListTile(),
                SizedBox(height: spacing.xs),
              ],
            ],
          ),
        ),
      ];
    }
    if (vm.takings == null && vm.hasError) {
      return [
        PointyInlineMessage.error(message: l10n.cardSettlementLoadFailed),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: vm.load,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.treasuryRetry),
          ),
        ),
      ];
    }
    if (vm.days.isEmpty) {
      return [
        PointyInlineMessage(
          message: l10n.cardSettlementNoHeld,
          icon: Icons.inbox_outlined,
        ),
      ];
    }
    return [
      for (final day in vm.days)
        HeldDayTile(
          day: day,
          selected: vm.isSelected(day),
          expanded: _expanded.contains(day.key),
          payments: vm.paymentsFor(day),
          isLoadingPayments: vm.isLoadingPayments(day),
          hasPaymentsError: vm.hasPaymentsError(day),
          isExcluded: (payment) => vm.isExcluded(day, payment),
          onToggle: () => vm.toggleDay(day),
          onToggleExpanded: () => _toggleExpanded(day),
          onTogglePayment: (payment) => vm.togglePayment(day, payment),
        ),
    ];
  }
}

/// How sure the proposal is, in a sentence.
class _MatchBanner extends StatelessWidget {
  const _MatchBanner({required this.match});

  final SettlementMatch match;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final (tone, icon, title) = switch (match) {
      SettlementMatch.exact => (
        PointyCalloutTone.success,
        Icons.check_circle_outline,
        l10n.cardSettlementMatchExact,
      ),
      SettlementMatch.gross => (
        PointyCalloutTone.primary,
        Icons.info_outline,
        l10n.cardSettlementMatchGross,
      ),
      SettlementMatch.close => (
        PointyCalloutTone.neutral,
        Icons.info_outline,
        l10n.cardSettlementMatchClose,
      ),
      SettlementMatch.due => (
        PointyCalloutTone.warning,
        Icons.report_problem_outlined,
        l10n.cardSettlementMatchDue,
      ),
      SettlementMatch.none => (
        PointyCalloutTone.neutral,
        Icons.schedule,
        l10n.cardSettlementMatchNone,
      ),
    };
    return PointyDetailCallout(
      key: ValueKey('card_settlement_match_${match.apiValue}'),
      icon: icon,
      tone: tone,
      title: title,
    );
  }
}

/// Expected, received, and the difference — with what the difference means.
class _Summary extends StatelessWidget {
  const _Summary({required this.viewModel});

  final CardSettlementViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final expected = centsToDouble(viewModel.expectedCents);
    final amount = viewModel.amountCents;
    final difference = viewModel.differenceCents;

    final explanation = switch (difference) {
      null || 0 => null,
      final cents when cents < 0 => l10n.cardSettlementKeptMore(
        formatMoney(centsToDouble(-cents)),
      ),
      final cents => l10n.cardSettlementKeptLess(
        formatMoney(centsToDouble(cents)),
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySummaryList(
          rows: [
            PointySummaryRow(
              label: l10n.cardSettlementExpectedLabel,
              value: formatMoney(expected),
            ),
            PointySummaryRow(
              label: l10n.cardSettlementReceivedLabel,
              value: amount == null ? '—' : formatMoney(centsToDouble(amount)),
            ),
            PointySummaryRow(
              label: l10n.cardSettlementDifferenceLabel,
              value: difference == null
                  ? '—'
                  : treasurySignedMoney(centsToDouble(difference)),
              valueColor: (difference ?? 0) < 0 ? colors.danger : null,
              emphasized: true,
              dividerAbove: true,
            ),
          ],
        ),
        if (explanation != null) ...[
          SizedBox(height: spacing.sm),
          PointyInlineMessage(
            key: const ValueKey('card_settlement_difference_note'),
            message: explanation,
            icon: Icons.percent,
          ),
        ],
      ],
    );
  }
}
