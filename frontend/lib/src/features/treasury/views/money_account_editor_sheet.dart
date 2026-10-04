import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/money_position.dart';
import '../../../shared/components/components.dart';
import '../../../shared/payments/bank_picker_field.dart';
import '../../../shared/payments/libyan_banks.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/bank_routing.dart';
import '../view_models/money_position_view_model.dart';
import 'clearing_account_fields.dart';

/// Create or edit a place the shop's money sits.
///
/// Until now there was no way to do this in the app at all: every shop had the
/// one cash box and the one generic bank account the install seeds, and a
/// second bank meant a trip to the Django admin. That is the gap a shop with
/// two card terminals falls into, so the editor is the first half of this
/// feature and the terminal mapping is the second.
///
/// The bank identity fields (bank, account number, IBAN) appear only for a bank
/// account — a cash box has none, and the server clears them if one is sent, so
/// offering them here would be offering a field that silently does nothing.
Future<bool?> showMoneyAccountEditorSheet(
  BuildContext context, {
  required MoneyPositionViewModel viewModel,
  MoneyAccount? account,
}) {
  final routing = BankRoutingScope.maybeOf(context);
  return showAdaptiveFormSurface<bool>(
    context: context,
    size: AdaptiveModalSize.standard,
    builder: (sheetContext) => _MoneyAccountEditorSheet(
      viewModel: viewModel,
      routing: routing,
      account: account,
    ),
  );
}

class _MoneyAccountEditorSheet extends StatefulWidget {
  const _MoneyAccountEditorSheet({
    required this.viewModel,
    required this.routing,
    this.account,
  });

  final MoneyPositionViewModel viewModel;
  final BankRouting? routing;
  final MoneyAccount? account;

  @override
  State<_MoneyAccountEditorSheet> createState() =>
      _MoneyAccountEditorSheetState();
}

class _MoneyAccountEditorSheetState extends State<_MoneyAccountEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _accountNumberController;
  late final TextEditingController _ibanController;
  late final TextEditingController _openingBalanceController;

  late MoneyAccountKind _kind;
  late String _bankSlug;
  late bool _isDefault;
  late bool _isActive;
  late DateTime _openingAt;
  // Clearing accounts only.
  int? _settlesIntoId;
  late String _cutoff;
  late Set<int> _weekdays;
  late int _lagDays;
  bool _submitting = false;

  bool get _isNew => widget.account == null;

  @override
  void initState() {
    super.initState();
    final account = widget.account;
    _nameController = TextEditingController(text: account?.name ?? '');
    _accountNumberController = TextEditingController(
      text: account?.accountNumber ?? '',
    );
    _ibanController = TextEditingController(text: account?.iban ?? '');
    _openingBalanceController = TextEditingController(
      text: (account?.openingBalance ?? 0).toStringAsFixed(2),
    );
    // A new account is almost always the second bank — the cash box and the
    // first bank already exist — so that is what the form opens on.
    _kind = account?.kind ?? MoneyAccountKind.bank;
    _bankSlug = account?.bankSlug ?? '';
    _isDefault = account?.isDefault ?? false;
    _isActive = account?.isActive ?? true;
    _openingAt = account?.openingAt ?? DateTime.now();
    _settlesIntoId = account?.settlesIntoId;
    _cutoff = account?.settlementCutoff ?? MoneyAccount.defaultSettlementCutoff;
    _weekdays = _parseWeekdays(
      account?.settlementWeekdays ?? MoneyAccount.defaultSettlementWeekdays,
    );
    _lagDays = account?.settlementLagDays ?? 1;
  }

  /// The active bank accounts a processor could pay into.
  List<MoneyAccount> get _banks => [
    for (final entry in widget.viewModel.accounts)
      if (entry.account.isBank && entry.account.isActive) entry.account,
  ];

  void _chooseKind(MoneyAccountKind kind, AppLocalizations l10n) {
    setState(() {
      _kind = kind;
      if (kind != MoneyAccountKind.clearing) {
        return;
      }
      // What the owner would have typed, and the bank card money already
      // falls back to.
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = l10n.cardProviderMoamalat;
      }
      final banks = _banks;
      _settlesIntoId ??= banks
          .where((bank) => bank.isRouted)
          .followedBy(banks)
          .map((bank) => bank.id)
          .firstOrNull;
      _openingAt = DateTime.now();
    });
  }

  /// Turning a clearing account off is final, so it is asked once in words.
  Future<void> _setClearingActive(bool value, AppLocalizations l10n) async {
    if (value) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.treasuryClearingStopConfirmTitle),
        content: Text(l10n.treasuryClearingStopConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              MaterialLocalizations.of(dialogContext).cancelButtonLabel,
            ),
          ),
          FilledButton(
            key: const ValueKey('money_account_clearing_stop_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.treasuryClearingStopConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() => _isActive = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _accountNumberController.dispose();
    _ibanController.dispose();
    _openingBalanceController.dispose();
    super.dispose();
  }

  bool get _isBank => _kind == MoneyAccountKind.bank;
  bool get _isClearing => _kind == MoneyAccountKind.clearing;

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    if (_isClearing && (_settlesIntoId == null || _weekdays.isEmpty)) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _submitting = true);

    final draft = MoneyAccount(
      id: widget.account?.id ?? 0,
      name: _nameController.text.trim(),
      kind: _kind,
      // The bank's own name travels with the slug so a build that does not
      // carry the mark — or a later one whose register dropped the slug — can
      // still say which bank this is.
      bankName: _isBank ? _bankNameForSlug(_bankSlug) : '',
      bankSlug: _isBank ? _bankSlug : '',
      accountNumber: _isBank ? _accountNumberController.text.trim() : '',
      iban: _isBank ? _ibanController.text.trim() : '',
      // A clearing account never has an opening balance or the default flag:
      // what it holds is card sales Pointy already recorded.
      openingBalance: _isClearing
          ? 0
          : double.tryParse(_openingBalanceController.text.trim()) ?? 0,
      openingAt: _openingAt,
      isDefault: _isClearing ? false : _isDefault,
      isActive: _isActive,
      settlesIntoId: _isClearing ? _settlesIntoId : null,
      settlementCutoff: _cutoff,
      settlementWeekdays: (_weekdays.toList()..sort()).join(','),
      settlementLagDays: _lagDays,
      // Not on the form, but on the account. The whole form travels on every
      // save, so leaving these to their defaults reset an imported account's
      // notes and its place in the list each time anything was edited.
      displayOrder: widget.account?.displayOrder ?? 0,
      notes: widget.account?.notes ?? '',
    );

    final saved = await widget.viewModel.saveAccount(
      draft,
      accountId: widget.account?.id,
      routing: widget.routing,
    );
    if (!mounted) {
      return;
    }
    setState(() => _submitting = false);
    if (!saved) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            widget.viewModel.accountSaveError ?? l10n.treasuryAccountSaveFailed,
          ),
        ),
      );
      return;
    }
    Navigator.of(context).pop(true);
    messenger.showSnackBar(SnackBar(content: Text(l10n.treasuryAccountSaved)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return SafeArea(
      top: false,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: EdgeInsets.all(spacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointySectionHeader(
                title: _isNew
                    ? l10n.treasuryAccountNewTitle
                    : l10n.treasuryAccountEditTitle,
              ),
              SizedBox(height: spacing.md),
              // The kind is fixed once the account exists: changing it would
              // reroute every figure already derived against it.
              if (_isNew) ...[
                SegmentedButton<MoneyAccountKind>(
                  key: const ValueKey('money_account_kind_selector'),
                  segments: [
                    ButtonSegment(
                      value: MoneyAccountKind.bank,
                      icon: const Icon(Icons.account_balance_outlined),
                      label: Text(l10n.treasuryAccountKindBank),
                    ),
                    ButtonSegment(
                      value: MoneyAccountKind.cash,
                      icon: const Icon(Icons.savings_outlined),
                      label: Text(l10n.treasuryAccountKindCash),
                    ),
                    ButtonSegment(
                      value: MoneyAccountKind.clearing,
                      icon: const Icon(Icons.hourglass_bottom_outlined),
                      label: Text(l10n.treasuryAccountKindClearing),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (selection) =>
                      _chooseKind(selection.first, l10n),
                ),
                SizedBox(height: spacing.md),
              ],
              TextFormField(
                key: const ValueKey('money_account_name_field'),
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: l10n.treasuryAccountNameLabel,
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? l10n.treasuryAccountNameRequired
                    : null,
              ),
              if (_isBank) ...[
                SizedBox(height: spacing.sm),
                BankPickerField(
                  selectedSlug: _bankSlug,
                  onChanged: (slug) => setState(() {
                    _bankSlug = slug;
                    // A shop that has not named the account yet gets the bank's
                    // name for free — which is what they would have typed.
                    if (_nameController.text.trim().isEmpty) {
                      _nameController.text = _bankNameForSlug(slug);
                    }
                  }),
                ),
                SizedBox(height: spacing.sm),
                TextFormField(
                  key: const ValueKey('money_account_number_field'),
                  controller: _accountNumberController,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: l10n.treasuryAccountNumberLabel,
                  ),
                ),
                SizedBox(height: spacing.sm),
                TextFormField(
                  key: const ValueKey('money_account_iban_field'),
                  controller: _ibanController,
                  textDirection: TextDirection.ltr,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    // Spaces are how a statement prints an IBAN and how a
                    // shopkeeper types it; they are stripped rather than
                    // refused so the stored value and the QR always agree.
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z ]')),
                  ],
                  decoration: InputDecoration(
                    labelText: l10n.treasuryAccountIbanLabel,
                    helperText: l10n.treasuryAccountIbanHelper,
                    helperMaxLines: 3,
                  ),
                ),
              ],
              if (_isClearing) ...[
                SizedBox(height: spacing.sm),
                ClearingAccountFields(
                  isNew: _isNew,
                  banks: _banks,
                  settlesIntoId: _settlesIntoId,
                  settlesIntoName: widget.account?.settlesIntoName ?? '',
                  onSettlesIntoChanged: (value) =>
                      setState(() => _settlesIntoId = value),
                  startsOn: _openingAt,
                  onStartsOnChanged: (value) =>
                      setState(() => _openingAt = value),
                  cutoff: _cutoff,
                  onCutoffChanged: (value) => setState(() => _cutoff = value),
                  weekdays: _weekdays,
                  onWeekdaysChanged: (value) =>
                      setState(() => _weekdays = value),
                  lagDays: _lagDays,
                  onLagDaysChanged: (value) => setState(() => _lagDays = value),
                ),
                if (!_isNew)
                  SwitchListTile(
                    key: const ValueKey('money_account_active_switch'),
                    contentPadding: EdgeInsets.zero,
                    value: _isActive,
                    // A stopped clearing account stays stopped: reopening it
                    // would hold again what went straight to the bank.
                    onChanged: widget.account!.isActive
                        ? (value) => _setClearingActive(value, l10n)
                        : null,
                    title: Text(l10n.treasuryClearingActiveLabel),
                  ),
              ] else ...[
                SizedBox(height: spacing.sm),
                TextFormField(
                  key: const ValueKey('money_account_opening_balance_field'),
                  controller: _openingBalanceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                  ],
                  decoration: InputDecoration(
                    labelText: l10n.treasuryAccountOpeningBalanceLabel,
                  ),
                  // An unparseable entry used to be saved as zero without a word
                  // — the one number an owner correcting an import would never
                  // notice was wrong.
                  validator: (value) =>
                      double.tryParse((value ?? '').trim()) == null
                      ? l10n.treasuryAccountOpeningBalanceInvalid
                      : null,
                ),
                SizedBox(height: spacing.sm),
                _OpeningDateField(
                  value: _openingAt,
                  onChanged: (value) => setState(() => _openingAt = value),
                ),
                SizedBox(height: spacing.sm),
                SwitchListTile(
                  key: const ValueKey('money_account_default_switch'),
                  contentPadding: EdgeInsets.zero,
                  value: _isDefault,
                  onChanged: (value) => setState(() => _isDefault = value),
                  title: Text(l10n.treasuryAccountDefaultLabel),
                  subtitle: Text(l10n.treasuryAccountDefaultHint),
                ),
                if (!_isNew)
                  SwitchListTile(
                    key: const ValueKey('money_account_active_switch'),
                    contentPadding: EdgeInsets.zero,
                    value: _isActive,
                    onChanged: (value) => setState(() => _isActive = value),
                    title: Text(l10n.treasuryAccountActiveLabel),
                  ),
              ],
              SizedBox(height: spacing.md),
              FilledButton.icon(
                key: const ValueKey('money_account_save_button'),
                onPressed:
                    _submitting || (_isClearing && _isNew && _banks.isEmpty)
                    ? null
                    : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: PointySpinner(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: Text(l10n.treasuryAccountSaveButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OpeningDateField extends StatelessWidget {
  const _OpeningDateField({required this.value, required this.onChanged});

  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return InkWell(
      key: const ValueKey('money_account_opening_at_field'),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: DateTime(now.year - 10),
          lastDate: DateTime(now.year + 1),
        );
        if (picked != null) {
          onChanged(DateTime(picked.year, picked.month, picked.day));
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: l10n.treasuryAccountOpeningAtLabel,
          prefixIcon: const Icon(Icons.event_outlined),
          suffixIcon: const Icon(Icons.expand_more),
        ),
        child: Text(
          '${value.year}-${value.month.toString().padLeft(2, '0')}-'
          '${value.day.toString().padLeft(2, '0')}',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}

Set<int> _parseWeekdays(String value) {
  final days = <int>{};
  for (final part in value.split(',')) {
    final day = int.tryParse(part.trim());
    if (day != null && day >= 0 && day <= 6) {
      days.add(day);
    }
  }
  return days;
}

/// The bank's Arabic name, or blank when nothing is chosen.
String _bankNameForSlug(String slug) {
  if (slug.isEmpty) {
    return '';
  }
  return bankForSlug(slug)?.arabicName ?? '';
}
