import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../core/result.dart';
import '../../../data/models/card_terminal.dart';
import '../../../data/models/money_position.dart';
import '../../../data/repositories/treasury_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payments/bank_account_row.dart';
import '../../../shared/responsive/responsive.dart';
import '../../treasury/view_models/bank_routing.dart';

/// The shop's card machines, and the bank account each one feeds.
///
/// This replaces a dialog that collected a list of terminal ids and nothing
/// else. The ids alone answered one question — *is this slip ours?* — and left
/// the one a two-terminal shop actually has: a Jumhouria machine and an Aman
/// machine both produce "card" payments, and without this mapping both totals
/// land in whichever account happens to be the default, where no statement
/// will ever agree with them.
///
/// Saying it once here is what makes it automatic afterwards. Every slip
/// carries the id of the machine that printed it, so once a terminal names its
/// account the till routes the money itself and the cashier is never asked.
///
/// Writes go straight to the server, row by row, rather than into the settings
/// form's draft. A terminal is not a preference — it is a money route another
/// screen is already reading — and collecting the edits to apply on "save"
/// would leave the till routing by a mapping the owner had already changed.
Future<void> showCardTerminalsSheet(
  BuildContext context, {
  required TreasuryRepository repository,
}) {
  final routing = BankRoutingScope.maybeOf(context);
  return showAdaptiveFormSurface<void>(
    context: context,
    size: AdaptiveModalSize.expanded,
    builder: (sheetContext) =>
        _CardTerminalsSheet(repository: repository, routing: routing),
  );
}

class _CardTerminalsSheet extends StatefulWidget {
  const _CardTerminalsSheet({required this.repository, required this.routing});

  final TreasuryRepository repository;
  final BankRouting? routing;

  @override
  State<_CardTerminalsSheet> createState() => _CardTerminalsSheetState();
}

class _CardTerminalsSheetState extends State<_CardTerminalsSheet> {
  final _terminalIdController = TextEditingController();
  final _labelController = TextEditingController();

  List<CardTerminal> _terminals = const [];
  List<MoneyAccount> _accounts = const [];
  bool _loading = true;
  bool _busy = false;
  String? _terminalIdError;
  int? _newTerminalAccountId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _terminalIdController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final accounts = await widget.repository.loadAccounts();
    final terminals = await widget.repository.loadCardTerminals();
    if (!mounted) {
      return;
    }
    setState(() {
      if (accounts is Ok<List<MoneyAccount>>) {
        _accounts = accounts.value
            .where(
              (account) =>
                  account.isActive && account.kind == MoneyAccountKind.bank,
            )
            .toList(growable: false);
      }
      if (terminals is Ok<List<CardTerminal>>) {
        _terminals = terminals.value
            .where((terminal) => terminal.isActive)
            .toList(growable: false);
      }
      // Only ever the default when there is exactly one account: with two,
      // guessing is the mistake this whole screen exists to prevent.
      _newTerminalAccountId ??= _accounts.length == 1
          ? _accounts.first.id
          : null;
      _loading = false;
    });
  }

  /// Re-reads the server AND the till's cached copy, so a mapping changed here
  /// is in force at the next checkout rather than after a restart.
  Future<void> _reload() async {
    await _load();
    await widget.routing?.load(force: true);
  }

  String _normalize(String value) => value
      .toUpperCase()
      .split('')
      .where((character) => RegExp(r'[0-9A-Z]').hasMatch(character))
      .join();

  Future<void> _add() async {
    final l10n = AppLocalizations.of(context)!;
    final terminalId = _normalize(_terminalIdController.text);
    if (terminalId.isEmpty) {
      setState(() => _terminalIdError = l10n.trustedCardTerminalRequiredError);
      return;
    }
    if (_terminals.any((terminal) => terminal.terminalId == terminalId)) {
      setState(() => _terminalIdError = l10n.trustedCardTerminalDuplicateError);
      return;
    }

    setState(() {
      _busy = true;
      _terminalIdError = null;
    });
    final created = await widget.repository.createCardTerminal(
      CardTerminal(
        id: 0,
        terminalId: terminalId,
        label: _labelController.text.trim(),
        moneyAccountId: _newTerminalAccountId,
        displayOrder: _terminals.length,
      ),
    );
    if (!mounted) {
      return;
    }
    if (created is Ok<CardTerminal>) {
      _terminalIdController.clear();
      _labelController.clear();
    }
    await _reload();
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  Future<void> _setAccount(CardTerminal terminal, int? accountId) async {
    setState(() => _busy = true);
    await widget.repository.updateCardTerminal(terminal.id, {
      'money_account': accountId,
    });
    await _reload();
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  Future<void> _remove(CardTerminal terminal) async {
    setState(() => _busy = true);
    await widget.repository.deleteCardTerminal(terminal.id);
    await _reload();
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointySectionHeader(title: l10n.trustedCardTerminalsDialogTitle),
            SizedBox(height: spacing.sm),
            Text(l10n.trustedCardTerminalsDialogDescription),
            SizedBox(height: spacing.md),
            if (_accounts.isEmpty && !_loading) ...[
              PointyInlineMessage(
                key: const ValueKey('card_terminals_no_accounts'),
                icon: Icons.account_balance_outlined,
                message: l10n.trustedCardTerminalNoBankAccounts,
              ),
              SizedBox(height: spacing.md),
            ],
            _AddTerminalForm(
              terminalIdController: _terminalIdController,
              labelController: _labelController,
              accounts: _accounts,
              accountId: _newTerminalAccountId,
              errorText: _terminalIdError,
              enabled: !_busy,
              onAccountChanged: (value) =>
                  setState(() => _newTerminalAccountId = value),
              onChanged: () {
                if (_terminalIdError != null) {
                  setState(() => _terminalIdError = null);
                }
              },
              onAdd: _add,
            ),
            SizedBox(height: spacing.md),
            if (_loading)
              const PointySkeleton(child: PointySkeletonBox(height: 120))
            else if (_terminals.isEmpty)
              PointyInlineMessage(
                message: l10n.trustedCardTerminalAllowAnyMessage,
                icon: Icons.info_outline,
                compact: true,
              )
            else
              for (final terminal in _terminals) ...[
                _TerminalRow(
                  terminal: terminal,
                  accounts: _accounts,
                  enabled: !_busy,
                  onAccountChanged: (value) => _setAccount(terminal, value),
                  onRemove: () => _remove(terminal),
                ),
                SizedBox(height: spacing.sm),
              ],
            SizedBox(height: spacing.sm),
            FilledButton(
              key: const ValueKey('card_terminals_done_button'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.closeButton),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddTerminalForm extends StatelessWidget {
  const _AddTerminalForm({
    required this.terminalIdController,
    required this.labelController,
    required this.accounts,
    required this.accountId,
    required this.errorText,
    required this.enabled,
    required this.onAccountChanged,
    required this.onChanged,
    required this.onAdd,
  });

  final TextEditingController terminalIdController;
  final TextEditingController labelController;
  final List<MoneyAccount> accounts;
  final int? accountId;
  final String? errorText;
  final bool enabled;
  final ValueChanged<int?> onAccountChanged;
  final VoidCallback onChanged;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const ValueKey('trusted_card_terminal_id_field'),
          controller: terminalIdController,
          enabled: enabled,
          textDirection: TextDirection.ltr,
          textInputAction: TextInputAction.next,
          onChanged: (_) => onChanged(),
          decoration: InputDecoration(
            labelText: l10n.trustedCardTerminalIdFieldLabel,
            hintText: l10n.trustedCardTerminalIdFieldHint,
            errorText: errorText,
            prefixIcon: const Icon(Icons.badge_outlined),
          ),
        ),
        SizedBox(height: spacing.sm),
        TextFormField(
          key: const ValueKey('trusted_card_terminal_label_field'),
          controller: labelController,
          enabled: enabled,
          decoration: InputDecoration(
            labelText: l10n.trustedCardTerminalLabelFieldLabel,
            hintText: l10n.trustedCardTerminalLabelFieldHint,
            prefixIcon: const Icon(Icons.label_outline),
          ),
        ),
        if (accounts.isNotEmpty) ...[
          SizedBox(height: spacing.sm),
          _AccountDropdown(
            fieldKey: const ValueKey('trusted_card_terminal_account_field'),
            accounts: accounts,
            value: accountId,
            enabled: enabled,
            onChanged: onAccountChanged,
          ),
        ],
        SizedBox(height: spacing.sm),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FilledButton.tonalIcon(
            key: const ValueKey('add_trusted_card_terminal_button'),
            onPressed: enabled ? onAdd : null,
            icon: const Icon(Icons.add),
            label: Text(l10n.addTrustedCardTerminalButton),
          ),
        ),
      ],
    );
  }
}

/// One machine: its id, what the staff call it, and where its money goes.
class _TerminalRow extends StatelessWidget {
  const _TerminalRow({
    required this.terminal,
    required this.accounts,
    required this.enabled,
    required this.onAccountChanged,
    required this.onRemove,
  });

  final CardTerminal terminal;
  final List<MoneyAccount> accounts;
  final bool enabled;
  final ValueChanged<int?> onAccountChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    return DecoratedBox(
      key: ValueKey('card_terminal_row_${terminal.terminalId}'),
      decoration: BoxDecoration(
        color: colors.surfaceSunken.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.point_of_sale_outlined,
                  size: 20,
                  color: colors.mutedInk,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (terminal.label.isNotEmpty)
                        Text(
                          terminal.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      Text(
                        ltrIsolated(terminal.terminalId),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: terminal.label.isEmpty
                            ? theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              )
                            : theme.textTheme.bodySmall?.copyWith(
                                color: colors.mutedInk,
                              ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey(
                    'remove_trusted_card_terminal_${terminal.terminalId}',
                  ),
                  tooltip: l10n.trustedCardTerminalRemoveTooltip,
                  onPressed: enabled ? onRemove : null,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            if (accounts.isNotEmpty) ...[
              SizedBox(height: spacing.xs),
              _AccountDropdown(
                fieldKey: ValueKey(
                  'card_terminal_account_${terminal.terminalId}',
                ),
                accounts: accounts,
                value: terminal.moneyAccountId,
                enabled: enabled,
                onChanged: onAccountChanged,
              ),
              // Not an error — an unmapped terminal routes exactly as every
              // terminal did before this screen existed — but worth saying,
              // because an owner who mapped one machine and not the other is
              // usually halfway through a job.
              if (!terminal.isMapped) ...[
                SizedBox(height: spacing.xs),
                PointyInlineMessage.warning(
                  compact: true,
                  message: l10n.trustedCardTerminalUnmappedWarning,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _AccountDropdown extends StatelessWidget {
  const _AccountDropdown({
    required this.fieldKey,
    required this.accounts,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final Key fieldKey;
  final List<MoneyAccount> accounts;
  final int? value;
  final bool enabled;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return DropdownButtonFormField<int?>(
      key: fieldKey,
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: l10n.trustedCardTerminalAccountLabel,
        isDense: true,
      ),
      items: [
        // "Not said" stays first and stays reachable: it is what every
        // terminal was before this feature, and it must be possible to go
        // back to it.
        DropdownMenuItem<int?>(
          value: null,
          child: Text(l10n.trustedCardTerminalAccountUnset),
        ),
        for (final account in accounts)
          DropdownMenuItem<int?>(
            value: account.id,
            child: BankAccountRow(
              account: account.asRef,
              compact: true,
              markSize: 20,
            ),
          ),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}
