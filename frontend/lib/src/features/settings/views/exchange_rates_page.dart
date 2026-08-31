import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/exchange_rate.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/exchange_rates_view_model.dart';

/// Shop Settings sub-page for exchange rates.
///
/// Two jobs, in this order. First, tell the owner what the shop is currently
/// pricing at and how much to trust it — the age of each rate, whether it came
/// from the feed or their own hand, and whether it is even the settlement series
/// they asked for. Second, turn a rate move into a decision: the repricing list
/// shows what has drifted and by how much, and nothing changes until they tick
/// it and confirm.
class ExchangeRatesPage extends StatefulWidget {
  const ExchangeRatesPage({super.key, required this.viewModel});

  final ExchangeRatesViewModel viewModel;

  @override
  State<ExchangeRatesPage> createState() => _ExchangeRatesPageState();
}

class _ExchangeRatesPageState extends State<ExchangeRatesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.viewModel.load());
    });
  }

  Future<void> _sync() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final ok = await widget.viewModel.syncNow();
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok ? l10n.exchangeRatesSyncedMessage : l10n.exchangeRatesSyncError,
        ),
      ),
    );
  }

  Future<void> _enterManualRate() async {
    final l10n = AppLocalizations.of(context)!;
    final draft = await showModalBottomSheet<ManualRateDraft>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _ManualRateSheet(
        currencies: widget.viewModel.quotableCurrencies,
        baseCode: widget.viewModel.rates.baseCode,
        instrument: widget.viewModel.rates.instrument,
        bankCode: widget.viewModel.rates.bankCode,
      ),
    );
    if (draft == null || !mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final ok = await widget.viewModel.recordManualRate(draft);
    if (!mounted) {
      return;
    }
    if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.manualRateSavedMessage)),
      );
    }
  }

  Future<void> _applyReprice() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final count = await widget.viewModel.applySelectedReprice();
    if (!mounted || count == 0) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.repricingAppliedMessage(count))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.exchangeRatesTitle),
            isLoading: viewModel.isBusy,
            actions: [
              IconButton(
                tooltip: l10n.exchangeRatesSyncNow,
                onPressed: viewModel.isBusy ? null : _sync,
                icon: viewModel.isSyncing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: PointySpinner(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: viewModel.isBusy ? null : _enterManualRate,
            icon: const Icon(Icons.edit_outlined),
            label: Text(l10n.manualRateTitle),
          ),
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;

    if (viewModel.isLoading && !viewModel.hasRates) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && !viewModel.hasRates) {
      return PointyErrorState(
        title: l10n.exchangeRatesLoadError,
        icon: Icons.currency_exchange_outlined,
        action: FilledButton.icon(
          onPressed: viewModel.load,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    final spacing = AdaptiveSpacing.of(context);
    return RefreshIndicator(
      onRefresh: viewModel.load,
      child: ListView(
        padding: spacing.pagePadding,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          AdaptiveMaxWidth(
            width: AppContentWidth.detail,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettlementSummary(rates: viewModel.rates),
                SizedBox(height: spacing.md),
                if (!viewModel.hasRates)
                  PointyEmptyState(
                    icon: Icons.currency_exchange_outlined,
                    title: l10n.exchangeRatesEmpty,
                    message: l10n.exchangeRatesEmptyHint,
                  )
                else
                  PointySettingsSection(
                    children: [
                      for (final rate in viewModel.rates.rates)
                        _RateRow(rate: rate),
                    ],
                  ),
                if (viewModel.proposals.isNotEmpty) ...[
                  SizedBox(height: spacing.lg),
                  _RepricingSection(
                    viewModel: viewModel,
                    onApply: _applyReprice,
                  ),
                ],
                SizedBox(height: spacing.xl),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// How this shop settles, and whether anything is wrong with the rates it has.
class _SettlementSummary extends StatelessWidget {
  const _SettlementSummary({required this.rates});

  final CurrentRates rates;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final instrumentLabel = rates.instrument == SettlementInstrument.bank
        ? l10n.settlementInstrumentBank
        : l10n.settlementInstrumentCash;

    return PointyDetailCallout(
      icon: Icons.account_balance_wallet_outlined,
      title:
          '${l10n.settlementInstrumentLabel}: $instrumentLabel'
          '${rates.bankCode.isNotEmpty ? ' · ${rates.bankCode.toUpperCase()}' : ''}',
      message: l10n.settlementInstrumentHelp,
      tone: rates.hasStaleRates || rates.hasSubstitutions
          ? PointyCalloutTone.warning
          : PointyCalloutTone.neutral,
      trailing: rates.hasStaleRates
          ? PointyStatusPill(
              label: l10n.exchangeRateStaleBadge,
              icon: Icons.schedule,
              color: colors.warning,
            )
          : null,
    );
  }
}

class _RateRow extends StatelessWidget {
  const _RateRow({required this.rate});

  final ResolvedRate rate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    final age = rate.ageHours >= 48
        ? l10n.exchangeRateAgeDays((rate.ageHours / 24).round())
        : l10n.exchangeRateAgeHours(rate.ageHours.round());

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  formatExchangeRate(rate.rate, rate.fromCode, rate.toCode),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              PointyStatusPill(
                label: rate.source.isManual
                    ? l10n.exchangeRateSourceManual
                    : l10n.exchangeRateSourceRelay,
                icon: rate.source.isManual
                    ? Icons.edit_outlined
                    : Icons.cloud_done_outlined,
                color: rate.source.isManual
                    ? colors.primaryStrong
                    : colors.mutedInk,
              ),
            ],
          ),
          SizedBox(height: spacing.xs),
          Row(
            children: [
              Icon(Icons.schedule, size: 14, color: colors.mutedInk),
              SizedBox(width: spacing.xs),
              Text(
                age,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: rate.isStale ? colors.warning : colors.mutedInk,
                ),
              ),
              if (rate.isStale) ...[
                SizedBox(width: spacing.sm),
                PointyStatusPill(
                  label: l10n.exchangeRateStaleBadge,
                  color: colors.warning,
                ),
              ],
            ],
          ),
          // A substituted series is the quiet costing error this whole screen
          // exists to prevent, so it is spelled out rather than implied.
          if (rate.isSubstituted) ...[
            SizedBox(height: spacing.xs),
            Text(
              l10n.exchangeRateSubstitutedWarning(
                rate.instrument == SettlementInstrument.bank
                    ? l10n.settlementInstrumentBank
                    : l10n.settlementInstrumentCash,
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: colors.warning),
            ),
          ],
        ],
      ),
    );
  }
}

class _RepricingSection extends StatelessWidget {
  const _RepricingSection({required this.viewModel, required this.onApply});

  final ExchangeRatesViewModel viewModel;
  final Future<void> Function() onApply;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final actionable = viewModel.proposals
        .where((p) => !p.unpriceable)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(
          title: l10n.repricingTitle,
          subtitle: l10n.repricingDriftCount(actionable.length),
          trailing: TextButton(
            onPressed: viewModel.selectedProposals.length == actionable.length
                ? viewModel.clearSelection
                : viewModel.selectAll,
            child: Text(l10n.bulkSelectAllAction),
          ),
        ),
        SizedBox(height: spacing.sm),
        PointySettingsSection(
          children: [
            for (final proposal in viewModel.proposals)
              _ProposalRow(
                proposal: proposal,
                selected: viewModel.isSelected(proposal),
                onChanged: proposal.unpriceable
                    ? null
                    : (value) => viewModel.toggle(proposal, value ?? false),
              ),
          ],
        ),
        SizedBox(height: spacing.md),
        FilledButton.icon(
          onPressed: viewModel.selectedProposals.isEmpty || viewModel.isApplying
              ? null
              : onApply,
          icon: const Icon(Icons.price_change_outlined),
          label: Text(l10n.repricingApply),
        ),
        SizedBox(height: spacing.xs),
        Text(
          l10n.repricingNothingToDo,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
      ],
    );
  }
}

class _ProposalRow extends StatelessWidget {
  const _ProposalRow({
    required this.proposal,
    required this.selected,
    required this.onChanged,
  });

  final PriceProposal proposal;
  final bool selected;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    if (proposal.unpriceable) {
      return ListTile(
        leading: Icon(Icons.help_outline, color: colors.warning),
        title: Text(proposal.label),
        subtitle: Text(
          l10n.repricingUnpriceable,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.warning),
        ),
      );
    }

    final direction = proposal.isIncrease ? '▲' : '▼';
    final tone = proposal.isIncrease ? colors.success : colors.danger;

    return CheckboxListTile(
      value: selected,
      onChanged: onChanged,
      title: Text(proposal.label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatDualPrice(
              proposal.priceAmount,
              proposal.currencyCode,
              proposal.proposedBasePrice ?? proposal.currentBasePrice,
            ),
            style: theme.textTheme.bodySmall,
          ),
          Text(
            '${formatMoney(proposal.currentBasePrice)} → '
            '${formatMoney(proposal.proposedBasePrice ?? proposal.currentBasePrice)} '
            '$direction ${proposal.deltaPercent.abs().toStringAsFixed(1)}%',
            style: theme.textTheme.bodySmall?.copyWith(color: tone),
          ),
        ],
      ),
    );
  }
}

class _ManualRateSheet extends StatefulWidget {
  const _ManualRateSheet({
    required this.currencies,
    required this.baseCode,
    required this.instrument,
    required this.bankCode,
  });

  final List<Currency> currencies;
  final String baseCode;
  final SettlementInstrument instrument;
  final String bankCode;

  @override
  State<_ManualRateSheet> createState() => _ManualRateSheetState();
}

class _ManualRateSheetState extends State<_ManualRateSheet> {
  final _formKey = GlobalKey<FormState>();
  final _rateController = TextEditingController();
  final _noteController = TextEditingController();
  String? _currencyCode;

  @override
  void initState() {
    super.initState();
    _currencyCode = widget.currencies.isNotEmpty
        ? widget.currencies.first.code
        : null;
  }

  @override
  void dispose() {
    _rateController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false) ||
        _currencyCode == null) {
      return;
    }
    Navigator.of(context).pop(
      ManualRateDraft(
        fromCode: _currencyCode!,
        toCode: widget.baseCode,
        rate: double.parse(_rateController.text.trim()),
        instrument: widget.instrument,
        bankCode: widget.bankCode,
        note: _noteController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        spacing.md,
        spacing.md,
        spacing.md,
        MediaQuery.of(context).viewInsets.bottom + spacing.md,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.manualRateTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: spacing.sm),
            Text(
              l10n.manualRateWinsHint,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
            SizedBox(height: spacing.md),
            DropdownButtonFormField<String>(
              initialValue: _currencyCode,
              decoration: InputDecoration(
                labelText: l10n.manualRateCurrencyLabel,
              ),
              items: [
                for (final currency in widget.currencies)
                  DropdownMenuItem(
                    value: currency.code,
                    child: Text('${currency.name} (${currency.code})'),
                  ),
              ],
              onChanged: (value) => setState(() => _currencyCode = value),
            ),
            SizedBox(height: spacing.md),
            TextFormField(
              controller: _rateController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: l10n.manualRateValueLabel(widget.baseCode),
              ),
              validator: (value) {
                final parsed = double.tryParse((value ?? '').trim());
                if (parsed == null || parsed <= 0) {
                  return l10n.manualRateInvalid;
                }
                return null;
              },
            ),
            SizedBox(height: spacing.md),
            TextFormField(
              controller: _noteController,
              decoration: InputDecoration(labelText: l10n.manualRateNoteLabel),
            ),
            SizedBox(height: spacing.lg),
            FilledButton(onPressed: _submit, child: Text(l10n.manualRateSave)),
          ],
        ),
      ),
    );
  }
}
