import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/service_quote.dart';
import '../../../../data/models/services_directory.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../direct_services/foreign_amount.dart';
import '../../view_models/airtime_view_model.dart';
import '../../view_models/service_blocker.dart';
import '../../view_models/service_quote_controller.dart';
import 'airtime_amount_step.dart';
import 'airtime_phone_step.dart';
import 'airtime_recents_row.dart';
import 'service_country_picker.dart';
import 'service_flag.dart';
import 'service_read_back.dart';
import 'service_needs_line.dart';
import 'service_step_indicator.dart';
import 'service_summary_card.dart';
import 'service_test_mode_banner.dart';
import 'service_texts.dart';
import 'service_timeline.dart';
import 'services_unavailable_state.dart';

/// The steps of a direct top-up, in the order the cashier takes them.
enum AirtimeFlowStep { country, number, amount, summary }

/// The step a flow opens at: where the form already stands, so a recent number
/// or a half-filled top-up resumes instead of starting over.
AirtimeFlowStep airtimeStartStep(AirtimeViewModel vm) {
  if (vm.canAdd && vm.readyQuote != null) {
    return AirtimeFlowStep.summary;
  }
  if (vm.operator != null && vm.hasPlausibleNumber) {
    return vm.amount != null && vm.customProblem == null
        ? AirtimeFlowStep.summary
        : AirtimeFlowStep.amount;
  }
  return vm.country == null ? AirtimeFlowStep.country : AirtimeFlowStep.number;
}

/// Opens the stepped direct top-up (country, number and network, amount,
/// summary) and resolves to the priced quote when the cashier adds it to the
/// cart, else null. Modal, like the bills flow: the till's hotkeys and barcode
/// listener cannot reach the fields in it.
///
/// [onAdd] puts the top-up in the cart and says whether it went in; when it
/// did not, the dialog stays open with what the cashier built, and says so.
Future<ServiceQuote?> showAirtimeFlow(
  BuildContext context, {
  required AirtimeViewModel viewModel,
  bool canSell = true,
  bool testMode = false,
  bool Function(ServiceQuote quote)? onAdd,
  Future<bool> Function()? onTransferBalance,
}) {
  return showAdaptiveFormSurface<ServiceQuote>(
    context: context,
    size: AdaptiveModalSize.standard,
    builder: (surfaceContext) => AirtimeFlowSheet(
      viewModel: viewModel,
      testMode: testMode,
      onTransferBalance: onTransferBalance,
      onAdd: canSell
          ? (quote) {
              final accepted = onAdd?.call(quote) ?? true;
              if (accepted) {
                viewModel.afterAdded();
                Navigator.of(surfaceContext).pop(quote);
              }
              return accepted;
            }
          : null,
      onClose: () => Navigator.of(surfaceContext).pop(),
    ),
  );
}

/// The flow itself, parameter-driven so the preview harness and tests draw it
/// without a till behind it. The view model is the till's, shared with the
/// launcher, and outlives the dialog.
class AirtimeFlowSheet extends StatefulWidget {
  const AirtimeFlowSheet({
    super.key,
    required this.viewModel,
    required this.onAdd,
    required this.onClose,
    this.onTransferBalance,
    this.testMode = false,
    this.initialStep,
  });

  final AirtimeViewModel viewModel;
  final bool testMode;

  /// Puts the priced top-up in the cart and says whether it went in. Null on
  /// a till that cannot sell.
  final bool Function(ServiceQuote quote)? onAdd;
  final Future<bool> Function()? onTransferBalance;
  final VoidCallback onClose;

  /// Overrides where the flow opens (previews, tests).
  final AirtimeFlowStep? initialStep;

  @override
  State<AirtimeFlowSheet> createState() => _AirtimeFlowSheetState();
}

class _AirtimeFlowSheetState extends State<AirtimeFlowSheet> {
  late AirtimeFlowStep _step =
      widget.initialStep ?? airtimeStartStep(widget.viewModel);
  bool _refused = false;

  AirtimeViewModel get _vm => widget.viewModel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_vm.catalog.ensureFresh());
        unawaited(_vm.loadRecents());
      }
    });
  }

  bool get _numberDone => _vm.operator != null && _vm.hasPlausibleNumber;
  bool get _amountDone => _vm.amount != null && _vm.customProblem == null;

  void _go(AirtimeFlowStep step) => setState(() {
    _step = step;
    _refused = false;
  });

  void _back() {
    if (_step.index > 0) {
      _go(AirtimeFlowStep.values[_step.index - 1]);
    }
  }

  void _pickCountry(ServiceCountry country) {
    _vm.selectCountry(country);
    _vm.requestPhoneFocus();
    _go(AirtimeFlowStep.number);
  }

  void _useRecent(RecentRecipient recipient) {
    _vm.useRecent(recipient);
    _go(airtimeStartStep(_vm));
  }

  void _afterNumber() {
    if (_numberDone) {
      _go(AirtimeFlowStep.amount);
    }
  }

  void _afterAmount() {
    _vm.priceNow();
    if (_amountDone) {
      _go(AirtimeFlowStep.summary);
    }
  }

  void _add() {
    final quote = _vm.readyQuote;
    final onAdd = widget.onAdd;
    if (quote != null && onAdd != null && !onAdd(quote)) {
      setState(() => _refused = true);
    }
  }

  Future<void> _transferBalance() async {
    final moved = await widget.onTransferBalance?.call() ?? false;
    if (moved && mounted) {
      unawaited(_vm.catalog.reload());
      _vm.quote.retry();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height = math.min(size.height * 0.92, 700.0);
    return SizedBox(
      height: height,
      child: ListenableBuilder(
        listenable: Listenable.merge([_vm, _vm.catalog]),
        builder: (context, _) => PopScope(
          canPop: _step == AirtimeFlowStep.country,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              _back();
            }
          },
          child: _content(context),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final spacing = AdaptiveSpacing.of(context);
    final vm = _vm;
    final step = _step;
    final testMode =
        widget.testMode || vm.catalog.isTestMode(country: vm.country?.code);

    final footer = switch (step) {
      AirtimeFlowStep.number => FilledButton(
        key: const ValueKey('airtime_next'),
        onPressed: _numberDone ? _afterNumber : null,
        child: Text(l10n.nextButton),
      ),
      AirtimeFlowStep.amount => FilledButton(
        key: const ValueKey('airtime_next'),
        onPressed: _amountDone ? _afterAmount : null,
        child: Text(l10n.nextButton),
      ),
      _ => null,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.xs,
            spacing.sm,
            spacing.xs,
            0,
          ),
          child: Row(
            children: [
              if (step != AirtimeFlowStep.country)
                IconButton(
                  key: const ValueKey('airtime_back'),
                  tooltip: l10n.backButton,
                  onPressed: _back,
                  icon: const Icon(Icons.arrow_back_rounded),
                )
              else
                const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.posServicesTabAirtime,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleLarge?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('airtime_help'),
                tooltip: l10n.posServicesHow,
                onPressed: () => showAirtimeHowSheet(context, _vm),
                icon: const Icon(Icons.help_outline_rounded),
              ),
              IconButton(
                key: const ValueKey('airtime_close'),
                tooltip: l10n.closeButton,
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.lg,
            0,
            spacing.lg,
            spacing.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (testMode) ...[
                const ServiceTestModeBanner(compact: true),
                const SizedBox(height: 8),
              ],
              ServiceStepIndicator(
                names: [
                  l10n.posBillStepNameCountry,
                  l10n.posBillStepNameAccount,
                  l10n.posBillStepNameAmount,
                  l10n.posBillStepNameSummary,
                ],
                index: step.index,
              ),
              if (step == AirtimeFlowStep.country) ...[
                const SizedBox(height: 8),
                ServiceNeedsLine(
                  text: l10n.posAirtimeNeeds,
                  textKey: const ValueKey('airtime_needs'),
                ),
              ],
            ],
          ),
        ),
        Divider(height: 1, color: colors.line),
        Expanded(
          child: SingleChildScrollView(
            key: ValueKey('airtime_body_${step.name}'),
            padding: EdgeInsets.fromLTRB(
              spacing.lg,
              spacing.md,
              spacing.lg,
              spacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _stepTitle(l10n),
                  style: textTheme.titleMedium?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: spacing.sm),
                _body(context),
              ],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(top: BorderSide(color: colors.line)),
          ),
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              spacing.lg,
              spacing.sm,
              spacing.lg,
              spacing.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (footer != null) ...[
                  SizedBox(height: 48, child: footer),
                  const SizedBox(height: 8),
                ],
                if (step != AirtimeFlowStep.summary)
                  const ServiceTimeline(compact: true),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _stepTitle(AppLocalizations l10n) => switch (_step) {
    AirtimeFlowStep.country => l10n.posBillStepCountryTitle,
    AirtimeFlowStep.number => l10n.posAirtimeStepNumber,
    AirtimeFlowStep.amount => l10n.posAirtimeStepAmount,
    AirtimeFlowStep.summary => l10n.posBillStepSummaryTitle,
  };

  Widget _body(BuildContext context) {
    final vm = _vm;
    switch (_step) {
      case AirtimeFlowStep.country:
        return _countryStep(context);
      case AirtimeFlowStep.number:
        final country = vm.country;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (country != null) ...[
              _SelectedCountry(
                country: country,
                onChange: () => _go(AirtimeFlowStep.country),
              ),
              const SizedBox(height: 12),
            ],
            AirtimePhoneStep(
              viewModel: vm,
              autofocus: false,
              onChangeCountry: () => _go(AirtimeFlowStep.country),
              onSubmitted: _afterNumber,
            ),
          ],
        );
      case AirtimeFlowStep.amount:
        return AirtimeAmountStep(viewModel: vm, onSubmitted: _afterAmount);
      case AirtimeFlowStep.summary:
        return _summary(context);
    }
  }

  Widget _countryStep(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final vm = _vm;
    final catalog = vm.catalog;
    final directory = catalog.directory;
    if (directory == null) {
      if (catalog.hasDirectoryError) {
        return PointyInlineMessage.error(
          key: const ValueKey('services_error'),
          message: l10n.posServicesLoadError,
          icon: Icons.cloud_off_outlined,
          trailing: TextButton.icon(
            onPressed: catalog.reload,
            icon: const Icon(Icons.sync),
            label: Text(l10n.retryButton),
          ),
        );
      }
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(child: PointySpinner()),
      );
    }
    final search = catalog.airtimeSearch;
    if (!directory.available ||
        directory.airtimeCountries.isEmpty ||
        search == null) {
      return ServicesUnavailableState(errorCode: directory.errorCode);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (vm.recents.isNotEmpty) ...[
          AirtimeRecentsRow(
            recents: vm.recents,
            catalog: catalog,
            onSelected: _useRecent,
          ),
          const SizedBox(height: 10),
        ],
        ServiceCountryPicker(
          key: const ValueKey('airtime_picker'),
          search: search,
          selectedCode: vm.country?.code,
          maxHeight: 360,
          showSearch: true,
          onSelected: _pickCountry,
        ),
        if (directory.unsupported.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            l10n.posAirtimeHowUnsupported(
              directory.unsupported.map((c) => c.label).join('\u{060C} '),
            ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.pointyColors.mutedInk,
            ),
          ),
        ],
      ],
    );
  }

  Widget _summary(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final vm = _vm;
    final country = vm.country;
    final operator = vm.operator;
    final quote = vm.quote.ready;
    final blocker = vm.blocker;
    final directory = vm.catalog.directory;
    final currency = operator == null
        ? ''
        : serviceCurrencyLabel(
            l10n,
            country,
            operator.receiveCurrency,
            directory: directory,
          );
    String? receives;
    if (operator != null) {
      final amount =
          quote?.receiveAmount ?? vm.selectedTile?.received ?? vm.amount;
      if (amount != null && amount.isNotEmpty) {
        final approximate = quote?.approximate ?? operator.approximate;
        receives =
            '${approximate ? '\u{2248}\u{2009}' : ''}${formatForeignAmountText(amount)} '
            '${serviceCurrencyLabel(l10n, country, quote?.receiveCurrency ?? operator.receiveCurrency, directory: directory)}';
      }
    }
    final balance = directory?.balance;
    final canAdd = vm.canAdd && widget.onAdd != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ServiceSummaryCard(
          key: const ValueKey('airtime_summary'),
          showTimeline: true,
          title: l10n.posServicesSummaryTitle,
          readBack: country == null
              ? null
              : ServiceReadBack(
                  number:
                      vm.serverNumber ??
                      (vm.national.isEmpty ? null : vm.displayNumber),
                  fromServer: vm.serverNumber != null,
                  country: country,
                  network: operator,
                  numberSize: 34,
                ),
          rows: [
            if (country == null) ...[
              ServiceSummaryRow(
                label: l10n.posServicesSummaryCountry,
                value: country?.label,
                leading: country == null
                    ? null
                    : ServiceFlag(code: country.code, width: 24, height: 16),
              ),
              ServiceSummaryRow(
                label: l10n.posServicesSummaryNumber,
                value:
                    vm.serverNumber ??
                    (vm.national.isEmpty ? null : vm.displayNumber),
                ltr: true,
              ),
              ServiceSummaryRow(
                label: l10n.posServicesSummaryNetwork,
                value: operator?.label,
              ),
            ],
            ServiceSummaryRow(
              label: l10n.posServicesSummaryReceives,
              value: receives,
              emphasis: true,
            ),
          ],
          priceLabel: l10n.posServicesSummaryPays,
          price: quote?.price,
          isPricing: vm.quote.status == ServiceQuoteStatus.loading,
          balanceText: balance == null
              ? null
              : l10n.posVoucherMenuBalance(formatMoney(balance)),
          exceedsBalance: quote?.exceedsFloat == true,
          onTransferBalance: widget.onTransferBalance == null
              ? null
              : _transferBalance,
          truth: l10n.posAirtimeTruth,
          addLabel: l10n.posServicesAddToCart,
          blockerText: blocker == null
              ? null
              : serviceBlockerText(l10n, blocker, currencyLabel: currency),
          blockerIsWaiting: blocker?.isWaiting ?? false,
          onRetry:
              blocker == null || !blocker.isRetryable && !blocker.needsFreshList
              ? null
              : (blocker.needsFreshList
                    ? vm.refreshList
                    : (blocker.reason == ServiceBlockReason.countryFailed
                          ? vm.retryCountry
                          : vm.quote.retry)),
          retryLabel: blocker != null && blocker.needsFreshList
              ? l10n.posServicesRefreshList
              : null,
          onAdd: canAdd ? _add : null,
        ),
        if (_refused) ...[
          const SizedBox(height: 10),
          PointyInlineMessage.warning(
            key: const ValueKey('service_add_refused'),
            message: l10n.posServicesAddRefused,
            icon: Icons.lock_clock_rounded,
            compact: true,
          ),
        ],
      ],
    );
  }
}

/// «كيف يعمل؟» for the direct top-up.
Future<void> showAirtimeHowSheet(BuildContext context, AirtimeViewModel vm) {
  final l10n = AppLocalizations.of(context)!;
  final unsupported = [
    for (final country in vm.catalog.directory?.unsupported ?? const [])
      country.label,
  ];
  return showAdaptiveModalBottomSheet<void>(
    context: context,
    builder: (_) => ServiceHowSheet(
      title: l10n.posAirtimeHowTitle,
      steps: [
        ServiceHowStep(
          icon: Icons.public_rounded,
          title: l10n.posAirtimeHowStep1Title,
          body: l10n.posAirtimeHowStep1Body,
        ),
        ServiceHowStep(
          icon: Icons.payments_outlined,
          title: l10n.posAirtimeHowStep2Title,
          body: l10n.posAirtimeHowStep2Body,
        ),
        ServiceHowStep(
          icon: Icons.receipt_long_rounded,
          title: l10n.posAirtimeHowStep3Title,
          body: l10n.posAirtimeHowStep3Body,
        ),
      ],
      timeline: true,
      facts: [
        l10n.posAirtimeHowNoRefund,
        if (unsupported.isNotEmpty)
          l10n.posAirtimeHowUnsupported(unsupported.join('\u{060C} ')),
      ],
    ),
  );
}

/// The chosen country, compact: its flag, its name, its calling code, and a
/// «تغيير» to go back to the list.
class _SelectedCountry extends StatelessWidget {
  const _SelectedCountry({required this.country, required this.onChange});

  final ServiceCountry country;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: const ValueKey('airtime_selected_country'),
      padding: const EdgeInsetsDirectional.only(
        start: 12,
        end: 4,
        top: 4,
        bottom: 4,
      ),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(PointyRadii.input),
        border: Border.all(color: colors.primaryStrong.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          ServiceFlag(code: country.code, width: 36, height: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              country.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleSmall?.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            '+${country.primaryDial}',
            textDirection: TextDirection.ltr,
            style: PointyTypography.numeric(
              (textTheme.titleSmall ?? const TextStyle()).copyWith(
                color: colors.mutedInk,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('airtime_change_country'),
            onPressed: onChange,
            child: Text(l10n.posServicesCountryChange),
          ),
        ],
      ),
    );
  }
}
