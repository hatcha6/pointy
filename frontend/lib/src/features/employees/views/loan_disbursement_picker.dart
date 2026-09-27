import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/employee.dart';
import '../../../data/models/money_position.dart';
import '../../../data/services/api_error_detail.dart';
import '../../../shared/design/design.dart';
import '../../../shared/payments/bank_account_picker.dart';
import '../../../shared/responsive/responsive.dart';
import '../../treasury/view_models/bank_routing.dart';

/// Where a loan's money comes from as it is handed over, held between
/// rebuilds: the cash box unless told otherwise.
class LoanDisbursementController extends ChangeNotifier {
  LoanDisbursementSource _source = LoanDisbursementSource.cashBox;
  int? _bankAccountId;
  bool _bankAccountChosen = false;

  LoanDisbursementSource get source => _source;

  set source(LoanDisbursementSource value) {
    if (value == _source) {
      return;
    }
    _source = value;
    notifyListeners();
  }

  /// The bank a transfer leaves: the one picked, or the picker's own first
  /// choice among [accounts] until one is.
  int? bankAccountIdFor(List<MoneyAccount> accounts) {
    return _bankAccountChosen
        ? _bankAccountId
        : BankAccountPicker.initialSelection(accounts);
  }

  void chooseBankAccount(int? id) {
    _bankAccountChosen = true;
    _bankAccountId = id;
    notifyListeners();
  }

  /// The hand-over as the server takes it.
  LoanDisbursement disbursementFor(List<MoneyAccount> accounts) {
    return LoanDisbursement(
      source: _source,
      moneyAccountId: _source == LoanDisbursementSource.bank
          ? bankAccountIdFor(accounts)
          : null,
    );
  }
}

/// Asks where a loan's money comes from: the giver's own open drawer, the
/// cash box, or a bank transfer from a chosen account. The approval of a
/// request and a loan given outright both ask it, the same way.
class LoanDisbursementPicker extends StatelessWidget {
  const LoanDisbursementPicker({
    super.key,
    required this.controller,
    this.enabled = true,
  });

  final LoanDisbursementController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final accounts = BankRoutingScope.accountsOf(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.loanDisbursementSourceLabel,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SizedBox(height: spacing.xs),
            for (final source in LoanDisbursementSource.values)
              _SourceOption(
                key: ValueKey('loan_source_${source.name}'),
                title: _sourceLabel(l10n, source),
                hint: _sourceHint(l10n, source),
                icon: _sourceIcon(source),
                selected: controller.source == source,
                enabled: enabled,
                onTap: () => controller.source = source,
              ),
            if (controller.source == LoanDisbursementSource.bank &&
                BankAccountPicker.isUseful(accounts)) ...[
              SizedBox(height: spacing.sm),
              BankAccountPicker(
                accounts: accounts,
                selectedId: controller.bankAccountIdFor(accounts),
                enabled: enabled,
                dense: true,
                onChanged: controller.chooseBankAccount,
              ),
            ],
          ],
        );
      },
    );
  }

  static String _sourceLabel(
    AppLocalizations l10n,
    LoanDisbursementSource source,
  ) {
    return switch (source) {
      LoanDisbursementSource.drawer => l10n.loanSourceDrawer,
      LoanDisbursementSource.cashBox => l10n.loanSourceCashBox,
      LoanDisbursementSource.bank => l10n.loanSourceBank,
    };
  }

  static String _sourceHint(
    AppLocalizations l10n,
    LoanDisbursementSource source,
  ) {
    return switch (source) {
      LoanDisbursementSource.drawer => l10n.loanSourceDrawerHint,
      LoanDisbursementSource.cashBox => l10n.loanSourceCashBoxHint,
      LoanDisbursementSource.bank => l10n.loanSourceBankHint,
    };
  }

  static IconData _sourceIcon(LoanDisbursementSource source) {
    return switch (source) {
      LoanDisbursementSource.drawer => Icons.point_of_sale_outlined,
      LoanDisbursementSource.cashBox => Icons.inventory_2_outlined,
      LoanDisbursementSource.bank => Icons.account_balance_outlined,
    };
  }
}

/// Why a loan — or the hand-over of its money — was refused, in words the
/// person can act on; [fallback] when the server gave no reason we know.
String loanFailureMessage(
  AppLocalizations l10n,
  Exception failure, {
  required String fallback,
}) {
  if (apiErrorCode(failure) == 'register_session_required') {
    return l10n.loanApproveSessionRequiredError;
  }
  if (apiRefusedForClosedPeriod(failure)) {
    return l10n.loanPeriodLockedError;
  }
  if (apiStatusCode(failure) == 403) {
    // The one right a hand-over can lack that the screen could not know:
    // taking cash out of a drawer.
    return l10n.loanApprovePermissionError;
  }
  if (apiErrorHasField(failure, 'employee')) {
    return l10n.loanEmployeeOffPayrollError;
  }
  return fallback;
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    super.key,
    required this.title,
    required this.hint,
    required this.icon,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String title;
  final String hint;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      selected: selected,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(hint),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? colors.primary : colors.mutedInk,
      ),
      onTap: onTap,
    );
  }
}
