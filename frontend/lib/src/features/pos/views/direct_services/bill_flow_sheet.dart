import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/service_kinds.dart';
import '../../../../data/models/service_quote.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../view_models/bill_flow_view_model.dart';
import 'bill_account_step.dart';
import 'bill_amount_step.dart';
import 'bill_provider_step.dart';
import 'bill_summary_step.dart';
import 'service_country_picker.dart';
import 'service_flag.dart';
import 'service_needs_line.dart';
import 'service_step_indicator.dart';
import 'service_test_mode_banner.dart';
import 'service_texts.dart';
import 'services_unavailable_state.dart';
import 'service_timeline.dart';

/// Opens the flow for paying one type of bill and resolves to the priced
/// quote when the cashier adds it to the cart, else null.
///
/// A dialog on a wide screen, a tall sheet on a phone — and modal either way,
/// so the till's hotkeys and its barcode listener cannot reach the fields in
/// it. The flow's view model lives exactly as long as the surface does.
///
/// [onAdd] puts the bill in the cart and says whether it went in: when it did
/// not, the dialog stays open with what the cashier built, and says so.
/// [onTransferBalance] opens the move of money from the wallet into the
/// voucher balance, for a user who may; it resolves to whether money moved.
Future<ServiceQuote?> showBillFlow(
  BuildContext context, {
  required BillFlowViewModel Function() create,
  bool canSell = true,
  bool testMode = false,
  bool Function(ServiceQuote quote)? onAdd,
  Future<bool> Function()? onTransferBalance,
}) {
  return showAdaptiveFormSurface<ServiceQuote>(
    context: context,
    size: AdaptiveModalSize.standard,
    builder: (surfaceContext) => _BillFlowHost(
      create: create,
      onAdd: canSell
          ? (quote) {
              final accepted = onAdd?.call(quote) ?? true;
              if (accepted) {
                Navigator.of(surfaceContext).pop(quote);
              }
              return accepted;
            }
          : null,
      onTransferBalance: onTransferBalance,
      testMode: testMode,
      onClose: () => Navigator.of(surfaceContext).pop(),
    ),
  );
}

class _BillFlowHost extends StatefulWidget {
  const _BillFlowHost({
    required this.create,
    required this.onAdd,
    required this.onClose,
    this.onTransferBalance,
    this.testMode = false,
  });

  final BillFlowViewModel Function() create;
  final bool Function(ServiceQuote quote)? onAdd;
  final Future<bool> Function()? onTransferBalance;
  final bool testMode;
  final VoidCallback onClose;

  @override
  State<_BillFlowHost> createState() => _BillFlowHostState();
}

class _BillFlowHostState extends State<_BillFlowHost> {
  late final BillFlowViewModel _viewModel = widget.create();

  @override
  void initState() {
    super.initState();
    unawaited(_viewModel.catalog.ensureFresh());
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BillFlowSheet(
    viewModel: _viewModel,
    onAdd: widget.onAdd,
    onTransferBalance: widget.onTransferBalance,
    testMode: widget.testMode,
    onClose: widget.onClose,
  );
}

/// The bill flow itself, parameter-driven so the preview harness and tests
/// draw it without a till behind it.
class BillFlowSheet extends StatelessWidget {
  const BillFlowSheet({
    super.key,
    required this.viewModel,
    required this.onAdd,
    required this.onClose,
    this.onTransferBalance,
    this.testMode = false,
  });

  final BillFlowViewModel viewModel;

  /// The menu says the relay is buying from its test supplier. The directory
  /// and the country, which the flow reads itself, say it too.
  final bool testMode;

  /// Puts the priced bill in the cart and says whether it went in. Null on a
  /// till that cannot sell.
  final bool Function(ServiceQuote quote)? onAdd;

  /// Moves money from the wallet into the voucher balance; null when this
  /// user cannot do it from here.
  final Future<bool> Function()? onTransferBalance;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // A tall surface, the same height at every step, so the steps do not
    // jump: all of a phone's height, most of a till's.
    final height = math.min(size.height * 0.92, 700.0);
    return SizedBox(
      height: height,
      child: ListenableBuilder(
        listenable: Listenable.merge([viewModel, viewModel.catalog]),
        // Esc and the system back button step back through the flow; only
        // from its first step do they close it, so a half-filled bill is not
        // thrown away by a stray key.
        builder: (context, _) => PopScope(
          canPop: !viewModel.canGoBack,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              viewModel.back();
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
    final vm = viewModel;
    final step = vm.step;
    final title = billTypeTitle(l10n, vm.type);

    final body = switch (step) {
      BillFlowStep.country => _countryStep(context),
      BillFlowStep.provider => BillProviderStep(viewModel: vm),
      BillFlowStep.account => BillAccountStep(
        key: ValueKey('bill_account_${vm.biller?.id}'),
        viewModel: vm,
      ),
      BillFlowStep.amount => BillAmountStep(viewModel: vm),
      BillFlowStep.summary => BillSummaryStep(
        viewModel: vm,
        onAdd: onAdd == null ? null : () => _add(),
        onTransferBalance: onTransferBalance,
      ),
    };

    final footer = switch (step) {
      BillFlowStep.account => FilledButton(
        key: const ValueKey('bill_next'),
        onPressed: vm.isAccountStepDone ? vm.continueFromAccount : null,
        child: Text(l10n.nextButton),
      ),
      BillFlowStep.amount when vm.isCustomOpen => FilledButton(
        key: const ValueKey('bill_next'),
        onPressed: vm.amount != null && vm.customProblem == null
            ? vm.continueFromAmount
            : null,
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
              if (vm.canGoBack)
                IconButton(
                  key: const ValueKey('bill_back'),
                  tooltip: l10n.backButton,
                  onPressed: vm.back,
                  icon: const Icon(Icons.arrow_back_rounded),
                )
              else
                const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleLarge?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('bill_help'),
                tooltip: l10n.posServicesHow,
                onPressed: () => _showHow(context),
                icon: const Icon(Icons.help_outline_rounded),
              ),
              IconButton(
                key: const ValueKey('bill_close'),
                tooltip: l10n.closeButton,
                onPressed: onClose,
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
              if (testMode ||
                  vm.catalog.isTestMode(country: vm.country?.code)) ...[
                const ServiceTestModeBanner(compact: true),
                const SizedBox(height: 8),
              ],
              _Breadcrumb(viewModel: vm, title: title),
              if (vm.country != null) const SizedBox(height: 8),
              ServiceStepIndicator(
                names: [
                  l10n.posBillStepNameCountry,
                  l10n.posBillStepNameProvider,
                  l10n.posBillStepNameAccount,
                  l10n.posBillStepNameAmount,
                  l10n.posBillStepNameSummary,
                ],
                index: step.index,
              ),
              const SizedBox(height: 8),
              ServiceNeedsLine(
                text: billNeeds(l10n, vm.type),
                textKey: const ValueKey('bill_needs'),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.line),
        Expanded(
          child: SingleChildScrollView(
            key: ValueKey('bill_body_${step.name}'),
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
                  _stepTitle(l10n, vm),
                  style: textTheme.titleMedium?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: spacing.sm),
                body,
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
                if (step != BillFlowStep.summary)
                  const ServiceTimeline(compact: true),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _stepTitle(AppLocalizations l10n, BillFlowViewModel vm) =>
      switch (vm.step) {
        BillFlowStep.country => l10n.posBillStepCountryTitle,
        BillFlowStep.provider => l10n.posBillStepProviderTitle,
        BillFlowStep.account =>
          vm.needsInvoice
              ? l10n.posBillStepAccountInvoiceTitle
              : l10n.posBillStepAccountTitle(billAccountLabel(l10n, vm.type)),
        BillFlowStep.amount =>
          vm.biller?.isFixed ?? false
              ? l10n.posBillStepPlanTitle
              : l10n.posBillStepAmountTitle,
        BillFlowStep.summary => l10n.posBillStepSummaryTitle,
      };

  Widget _countryStep(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final catalog = viewModel.catalog;
    final search = catalog.billSearch(viewModel.type);
    if (search == null) {
      if (catalog.hasDirectoryError) {
        return PointyInlineMessage.error(
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
    final directory = catalog.directory;
    if (directory == null || !directory.available || search.countries.isEmpty) {
      return ServicesUnavailableState(
        errorCode: directory?.errorCode ?? '',
        icon: Icons.receipt_long_rounded,
      );
    }
    return ServiceCountryPicker(
      search: search,
      selectedCode: viewModel.country?.code,
      showDial: false,
      tileRows: true,
      autofocus: search.countries.length > 8,
      maxHeight: 420,
      providerCount: viewModel.providerCount,
      onSelected: viewModel.selectCountry,
    );
  }

  void _add() {
    final quote = viewModel.readyQuote;
    final onAdd = this.onAdd;
    if (quote != null && onAdd != null && !onAdd(quote)) {
      viewModel.markAddRefused();
    }
  }

  Future<void> _showHow(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return showBillHowSheet(
      context,
      title: l10n.posBillHowTitle(billTypeTitle(l10n, viewModel.type)),
      electricityToken: viewModel.type == BillType.electricity,
    );
  }
}

/// «كيف يعمل؟» for paying a bill: the three steps and what is not possible.
/// [electricityToken] adds what a prepaid meter's receipt carries.
Future<void> showBillHowSheet(
  BuildContext context, {
  required String title,
  bool electricityToken = false,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showAdaptiveModalBottomSheet<void>(
    context: context,
    builder: (_) => ServiceHowSheet(
      title: title,
      steps: [
        ServiceHowStep(
          icon: Icons.flag_rounded,
          title: l10n.posBillHowStep1Title,
          body: l10n.posBillHowStep1Body,
        ),
        ServiceHowStep(
          icon: Icons.pin_outlined,
          title: l10n.posBillHowStep2Title,
          body: l10n.posBillHowStep2Body,
        ),
        ServiceHowStep(
          icon: Icons.receipt_long_rounded,
          title: l10n.posBillHowStep3Title,
          body: l10n.posBillHowStep3Body,
        ),
      ],
      facts: [
        l10n.posBillTruth,
        if (electricityToken) l10n.posBillHowElectricityToken,
      ],
    ),
  );
}

/// «كهرباء ‹ نيجيريا ‹ كهرباء إيكيجا»: what has been chosen so far, always on
/// screen; a tap on one goes back to it.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.viewModel, required this.title});

  final BillFlowViewModel viewModel;
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final vm = viewModel;
    final country = vm.country;
    final biller = vm.biller;
    final crumbs = <Widget>[
      if (country != null)
        _Crumb(
          key: const ValueKey('bill_crumb_country'),
          label: country.label,
          leading: ServiceFlag(code: country.code, width: 20, height: 13),
          onTap:
              vm.step.index > BillFlowStep.country.index && !vm.isCountryFixed
              ? () => vm.goTo(BillFlowStep.country)
              : null,
        ),
      if (biller != null && vm.step.index > BillFlowStep.provider.index)
        _Crumb(
          key: const ValueKey('bill_crumb_provider'),
          label: biller.label,
          onTap: vm.isProviderFixed
              ? null
              : () => vm.goTo(BillFlowStep.provider),
        ),
    ];
    if (crumbs.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final (index, crumb) in crumbs.indexed) ...[
          if (index > 0)
            Icon(Icons.chevron_right_rounded, size: 18, color: colors.mutedInk),
          crumb,
        ],
      ],
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({super.key, required this.label, this.leading, this.onTap});

  final String label;
  final Widget? leading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final tappable = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(PointyRadii.chip),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: tappable ? colors.primaryContainer : colors.subtleFill,
          borderRadius: BorderRadius.circular(PointyRadii.chip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 6)],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelMedium?.copyWith(
                  color: tappable ? colors.primaryDark : colors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
