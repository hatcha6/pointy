import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/report_catalog.dart';
import '../../../data/models/report_run.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../report_titles.dart';
import '../view_models/reports_view_model.dart';
import 'report_result_view.dart';

/// What a caller does with a finished run — preview it, print it, share it.
///
/// The run is passed in rather than rebuilt: preview, print and share used to
/// be three independent server-side rebuilds of the same report, so three
/// clicks on one report cost three aggregations and left three rows in the run
/// table.
typedef ReportRunAction = Future<void> Function(ReportRun run);

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    required this.capabilities,
    required this.navigation,
    required this.viewModel,
    this.contactRepository,
    this.onPreviewPdf,
    this.onPrintReport,
    this.onExportArchive,
    this.onSaveCsv,
  });

  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;
  final ReportsViewModel viewModel;
  final ContactRepository? contactRepository;
  final ReportRunAction? onPreviewPdf;
  final ReportRunAction? onPrintReport;
  final ReportRunAction? onExportArchive;

  /// Hands the exported CSV to the platform's save dialog. Returns the message
  /// to show, or null when the user dismissed the dialog.
  final Future<String?> Function()? onSaveCsv;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  _ReportOutputAction? _runningAction;

  @override
  void initState() {
    super.initState();
    unawaited(widget.viewModel.load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyScaffold(
      drawer: AppNavigationDrawer(
        selectedDestination: AppNavigationDestination.reports,
        navigation: widget.navigation,
      ),
      appBar: AppBar(
        leading: const PointyNavigationMenuButton(),
        title: Text(l10n.reportsTitle),
      ),
      body: ReportsGuard(
        capabilities: widget.capabilities,
        child: ListenableBuilder(
          listenable: widget.viewModel,
          builder: (context, _) => _ReportsWorkspace(
            viewModel: widget.viewModel,
            runningAction: _runningAction,
            onSelectType: _selectType,
            onOpenTypeDetails: _openDetails,
            onPickCustomer: _pickCustomer,
            onPickSupplier: _pickSupplier,
            onPickCustomRange: _pickCustomRange,
            onRunAction: _runAction,
            onManageLock: _manageLock,
            onSetFiscalYear: _setFiscalYear,
            onOpenDocument: _openDocument,
            onOpenHistoricRun: _openHistoricRun,
            onVerifyRun: _verifyRun,
          ),
        ),
      ),
    );
  }

  void _selectType(ReportRunType type) {
    widget.viewModel.selectType(type);
  }

  void _openDetails(ReportRunType type) {
    _selectType(type);
    unawaited(_showDetailsSheet());
  }

  Future<void> _showDetailsSheet() {
    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      maxHeightFactor: 0.92,
      builder: (sheetContext) {
        return _CompactReportDetailsSheet(
          child: ListenableBuilder(
            listenable: widget.viewModel,
            builder: (context, _) => SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ReportConfiguration(
                    viewModel: widget.viewModel,
                    runningAction: _runningAction,
                    onPickCustomer: _pickCustomer,
                    onPickSupplier: _pickSupplier,
                    onPickCustomRange: _pickCustomRange,
                    onRunAction: (action) => unawaited(_runAction(action)),
                  ),
                  const SizedBox(height: 24),
                  // A phone gets the figures too. The sheet used to end at the
                  // buttons, so the only way to read a number on a phone was to
                  // build a PDF and scroll it.
                  _ResultArea(
                    viewModel: widget.viewModel,
                    onOpenDocument: _openDocument,
                  ),
                  const SizedBox(height: 24),
                  _HistoryPanel(
                    viewModel: widget.viewModel,
                    onOpen: _openHistoricRun,
                    onVerify: _verifyRun,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickCustomRange() async {
    final range = widget.viewModel.customRange;
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: range,
      firstDate: DateTime(2020),
      // Never past today: a report of the future is always an accident, and
      // the picker used to allow a year of them.
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) {
      return;
    }
    widget.viewModel.selectCustomRange(picked);
  }

  Future<void> _pickCustomer() async {
    final repository = widget.contactRepository;
    if (repository == null) {
      return;
    }
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: repository,
    );
    if (customer == null || !mounted) {
      return;
    }
    widget.viewModel.selectCustomer(customer.id, customer.fullName);
  }

  Future<void> _pickSupplier() async {
    final repository = widget.contactRepository;
    if (repository == null) {
      return;
    }
    final supplier = await showSupplierPickerSheet(
      context: context,
      repository: repository,
    );
    if (supplier == null || !mounted) {
      return;
    }
    widget.viewModel.selectSupplier(supplier.id, supplier.name);
  }

  Future<void> _runAction(_ReportOutputAction action) async {
    if (_runningAction != null) {
      return;
    }
    setState(() => _runningAction = action);
    try {
      await _performAction(action);
    } finally {
      if (mounted) {
        setState(() => _runningAction = null);
      }
    }
  }

  Future<void> _performAction(_ReportOutputAction action) async {
    final l10n = AppLocalizations.of(context)!;

    if (action == _ReportOutputAction.exportCsv) {
      final message = await widget.onSaveCsv?.call();
      if (!mounted) {
        return;
      }
      _showMessage(message ?? widget.viewModel.errorMessage);
      return;
    }

    // One build serves every output. The result is held, so previewing then
    // printing then sharing is one aggregation rather than three.
    final run = await widget.viewModel.ensureRun();
    if (!mounted) {
      return;
    }
    if (run == null) {
      _showMessage(
        widget.viewModel.errorMessage.isEmpty
            ? l10n.reportGenerationError
            : widget.viewModel.errorMessage,
      );
      return;
    }

    final callback = switch (action) {
      _ReportOutputAction.run => null,
      _ReportOutputAction.previewPdf => widget.onPreviewPdf,
      _ReportOutputAction.printReport => widget.onPrintReport,
      _ReportOutputAction.exportArchive => widget.onExportArchive,
      _ReportOutputAction.exportCsv => null,
    };
    if (callback == null) {
      return;
    }
    try {
      await callback(run);
    } catch (_) {
      if (mounted) {
        _showMessage(l10n.reportActionError(_actionLabel(l10n, action)));
      }
    }
  }

  Future<void> _openHistoricRun(int id) async {
    final opened = await widget.viewModel.openHistoricRun(id);
    if (!mounted || opened) {
      return;
    }
    _showMessage(widget.viewModel.errorMessage);
  }

  Future<void> _verifyRun(int id) async {
    final l10n = AppLocalizations.of(context)!;
    final verification = await widget.viewModel.verifyRun(id);
    if (!mounted || verification == null) {
      return;
    }
    _showMessage(
      verification.matches
          ? l10n.reportVerifyMatchMessage
          : l10n.reportVerifyChangedMessage(
              '${verification.changedFigures.length}',
            ),
    );
  }

  /// Closing a period, or re-opening one.
  ///
  /// Re-opening is guarded twice on purpose: the server refuses it without an
  /// acknowledgement, and the dialog here says plainly what the acknowledgement
  /// means — already-reported figures become changeable again.
  Future<void> _manageLock() async {
    final l10n = AppLocalizations.of(context)!;
    final current = widget.viewModel.lock.lockedThrough;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: l10n.reportPeriodLockTitle,
    );
    if (picked == null || !mounted) {
      return;
    }

    var acknowledged = false;
    if (current != null && picked.isBefore(current)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => PointyConfirmationDialog(
          title: l10n.reportPeriodLockTitle,
          message: l10n.reportPeriodLockReopenWarning,
          confirmLabel: l10n.reportPeriodLockReopenAction,
          icon: Icons.lock_open_outlined,
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
      acknowledged = true;
    }

    final saved = await widget.viewModel.setPeriodLock(
      lockedThrough: picked,
      acknowledged: acknowledged,
    );
    if (!mounted) {
      return;
    }
    _showMessage(
      saved ? l10n.reportPeriodLockSavedMessage : widget.viewModel.errorMessage,
    );
  }

  /// Opens the document a report row names.
  ///
  /// A figure a reader cannot get behind is a figure they have to take on
  /// trust, and the assistant is the product's own answer to "show me this
  /// one" — it can find a receipt by its number and read it back, which no
  /// filtered list screen in the app can do today.
  void _openDocument(String reference) {
    final l10n = AppLocalizations.of(context)!;
    widget.navigation.openAiChat(
      context,
      seedPrompt: l10n.reportOpenDocumentPrompt(reference),
      autoSend: true,
      from: AppNavigationDestination.reports,
    );
  }

  /// The month the financial year opens on. A one-time setting, and the reason
  /// "this year" means the shop's year rather than January to December.
  Future<void> _setFiscalYear() async {
    final l10n = AppLocalizations.of(context)!;
    final localizations = MaterialLocalizations.of(context);
    final picked = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(l10n.reportFiscalYearStartLabel),
        children: [
          for (var month = 1; month <= 12; month++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(month),
              child: Text(
                localizations
                    .formatMonthYear(DateTime(2026, month))
                    .split(' ')
                    .first,
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    final saved = await widget.viewModel.setPeriodLock(
      includeLockedThrough: false,
      fiscalYearStartMonth: picked,
    );
    if (!mounted) {
      return;
    }
    _showMessage(
      saved
          ? l10n.reportFiscalYearSavedMessage
          : widget.viewModel.errorMessage,
    );
  }

  void _showMessage(String message) {
    if (message.isEmpty) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

class _ReportsWorkspace extends StatelessWidget {
  const _ReportsWorkspace({
    required this.viewModel,
    required this.runningAction,
    required this.onSelectType,
    required this.onOpenTypeDetails,
    required this.onPickCustomer,
    required this.onPickSupplier,
    required this.onPickCustomRange,
    required this.onRunAction,
    required this.onManageLock,
    required this.onSetFiscalYear,
    required this.onOpenDocument,
    required this.onOpenHistoricRun,
    required this.onVerifyRun,
  });

  final ReportsViewModel viewModel;
  final _ReportOutputAction? runningAction;
  final ValueChanged<ReportRunType> onSelectType;
  final ValueChanged<ReportRunType> onOpenTypeDetails;
  final Future<void> Function() onPickCustomer;
  final Future<void> Function() onPickSupplier;
  final Future<void> Function() onPickCustomRange;
  final Future<void> Function(_ReportOutputAction) onRunAction;
  final Future<void> Function() onManageLock;
  final Future<void> Function() onSetFiscalYear;
  final ValueChanged<String> onOpenDocument;
  final Future<void> Function(int) onOpenHistoricRun;
  final Future<void> Function(int) onVerifyRun;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final isCompact = width < AppBreakpoints.masterDetailMin;

        final catalog = _ReportCatalogPane(
          viewModel: viewModel,
          onSelectType: isCompact ? onOpenTypeDetails : onSelectType,
          onManageLock: onManageLock,
          onSetFiscalYear: onSetFiscalYear,
          isScrollable: !isCompact,
        );

        if (isCompact) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [catalog],
          );
        }

        return TwoPaneLayout(
          dualPaneBreakpoint: AppBreakpoints.masterDetailMin,
          secondaryFirst: true,
          secondaryPaneWidth: 380,
          secondaryPane: catalog,
          primaryPane: AdaptiveMaxWidth(
            width: AppContentWidth.list,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _ReportConfiguration(
                  viewModel: viewModel,
                  runningAction: runningAction,
                  onPickCustomer: onPickCustomer,
                  onPickSupplier: onPickSupplier,
                  onPickCustomRange: onPickCustomRange,
                  onRunAction: (action) => unawaited(onRunAction(action)),
                ),
                const SizedBox(height: 24),
                _ResultArea(
                  viewModel: viewModel,
                  onOpenDocument: onOpenDocument,
                ),
                const SizedBox(height: 24),
                _HistoryPanel(
                  viewModel: viewModel,
                  onOpen: onOpenHistoricRun,
                  onVerify: onVerifyRun,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CompactReportDetailsSheet extends StatelessWidget {
  const _CompactReportDetailsSheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return Material(
      key: const ValueKey('report_details_sheet'),
      color: colors.surface,
      borderRadius: BorderRadius.circular(PointyRadii.sheet),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(top: false, child: child),
    );
  }
}

// ---------------------------------------------------------------------------
// Catalogue
// ---------------------------------------------------------------------------

class _ReportCatalogPane extends StatelessWidget {
  const _ReportCatalogPane({
    required this.viewModel,
    required this.onSelectType,
    required this.onManageLock,
    required this.onSetFiscalYear,
    this.isScrollable = true,
  });

  final ReportsViewModel viewModel;
  final ValueChanged<ReportRunType> onSelectType;
  final Future<void> Function() onManageLock;
  final Future<void> Function() onSetFiscalYear;
  final bool isScrollable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final grouped = viewModel.reportsByCategory;

    final children = <Widget>[
      if (viewModel.isLoadingCatalog && grouped.isEmpty)
        const _SkeletonRows(count: 6)
      else if (viewModel.hasCatalogError && grouped.isEmpty)
        PointyErrorState(
          title: l10n.reportGenerationError,
          action: TextButton(
            onPressed: () => unawaited(viewModel.load()),
            child: Text(l10n.reportRunAgainButton),
          ),
        )
      else
        for (final entry in grouped.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: Text(
              reportCategoryLabel(l10n, entry.key),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: context.pointyColors.mutedInk,
              ),
            ),
          ),
          for (final report in entry.value)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _ReportTile(
                entry: report,
                isSelected: report.type == viewModel.selectedType,
                onTap: () => onSelectType(report.type),
              ),
            ),
        ],
      const SizedBox(height: 12),
      _PeriodLockCard(
        viewModel: viewModel,
        onManage: onManageLock,
        onSetFiscalYear: onSetFiscalYear,
      ),
    ];

    if (!isScrollable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionTitle(title: l10n.reportsCatalogTitle),
          ...children,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: _SectionTitle(title: l10n.reportsCatalogTitle),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: children,
          ),
        ),
      ],
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({
    required this.entry,
    required this.isSelected,
    required this.onTap,
  });

  final ReportCatalogEntry entry;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Card.filled(
      margin: EdgeInsets.zero,
      color: isSelected ? colors.primaryContainer : colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(
                _iconFor(entry.type),
                color: isSelected ? colors.primaryDark : colors.primaryStrong,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reportTitle(l10n, entry.type),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      reportSubtitle(l10n, entry.type),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (isSelected) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_circle, color: colors.primaryStrong),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

IconData _iconFor(ReportRunType type) {
  return switch (type) {
    ReportRunType.salesSummary => Icons.trending_up_outlined,
    ReportRunType.registerClosure => Icons.manage_history_outlined,
    ReportRunType.paymentMethods => Icons.payments_outlined,
    ReportRunType.inventoryStatus => Icons.inventory_2_outlined,
    ReportRunType.stockMovements => Icons.swap_vert,
    ReportRunType.purchasingSummary => Icons.add_shopping_cart_outlined,
    ReportRunType.reorderItems => Icons.production_quantity_limits_outlined,
    ReportRunType.payrollSummary => Icons.badge_outlined,
    ReportRunType.profitCosts => Icons.account_balance_outlined,
    ReportRunType.receivablesAging => Icons.request_quote_outlined,
    ReportRunType.payablesAging => Icons.receipt_long_outlined,
    ReportRunType.customerStatement => Icons.person_outline,
    ReportRunType.supplierStatement => Icons.local_shipping_outlined,
    ReportRunType.cashPosition => Icons.account_balance_wallet_outlined,
    ReportRunType.expenseBreakdown => Icons.pie_chart_outline,
    ReportRunType.productMargin => Icons.percent_outlined,
    ReportRunType.discountAudit => Icons.gavel_outlined,
    ReportRunType.salesByStaff => Icons.groups_outlined,
    ReportRunType.monthEndPack => Icons.menu_book_outlined,
  };
}

/// The accounting calendar: which month the year opens on, and how far the
/// books are closed.
///
/// Both controls live here rather than on the shop-settings screen because both
/// are bookkeeping acts, and the role that performs them — the accountant —
/// deliberately does not hold permission to edit shop settings.
class _PeriodLockCard extends StatelessWidget {
  const _PeriodLockCard({
    required this.viewModel,
    required this.onManage,
    required this.onSetFiscalYear,
  });

  final ReportsViewModel viewModel;
  final Future<void> Function() onManage;
  final Future<void> Function() onSetFiscalYear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final lock = viewModel.lock;
    final lockedThrough = lock.lockedThrough;

    return Card.filled(
      margin: EdgeInsets.zero,
      color: context.pointyColors.surfaceSunken,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.event_note_outlined,
                  size: 18,
                  color: context.pointyColors.mutedInk,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.reportAccountingCalendarTitle,
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${l10n.reportFiscalYearStartLabel}: '
              '${_monthName(context, lock.fiscalYearStartMonth)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              lockedThrough == null
                  ? l10n.reportPeriodLockOpen
                  : l10n.reportPeriodLockClosedThrough(
                      formatDate(lockedThrough),
                    ),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '${l10n.reportMonthEndSnapshotLabel}: '
              '${viewModel.snapshotDay == 0 ? l10n.reportMonthEndSnapshotOff : l10n.reportMonthEndSnapshotOnDay('${viewModel.snapshotDay}')}',
              style: theme.textTheme.bodySmall,
            ),
            if (lock.canManage) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: viewModel.isSavingLock
                        ? null
                        : () => unawaited(onManage()),
                    icon: const Icon(Icons.lock_outline, size: 18),
                    label: Text(
                      lockedThrough == null
                          ? l10n.reportPeriodLockCloseAction
                          : l10n.reportPeriodLockReopenAction,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: viewModel.isSavingLock
                        ? null
                        : () => unawaited(onSetFiscalYear()),
                    icon: const Icon(Icons.calendar_month_outlined, size: 18),
                    label: Text(l10n.reportFiscalYearStartAction),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _monthName(BuildContext context, int month) {
  final localizations = MaterialLocalizations.of(context);
  return localizations.formatMonthYear(DateTime(2026, month)).split(' ').first;
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

class _ReportConfiguration extends StatelessWidget {
  const _ReportConfiguration({
    required this.viewModel,
    required this.runningAction,
    required this.onPickCustomer,
    required this.onPickSupplier,
    required this.onPickCustomRange,
    required this.onRunAction,
  });

  final ReportsViewModel viewModel;
  final _ReportOutputAction? runningAction;
  final Future<void> Function() onPickCustomer;
  final Future<void> Function() onPickSupplier;
  final Future<void> Function() onPickCustomRange;
  final ValueChanged<_ReportOutputAction> onRunAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entry = viewModel.selectedEntry;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SelectedReportHeader(viewModel: viewModel),
        const SizedBox(height: 20),
        _PeriodPanel(
          viewModel: viewModel,
          onPickCustomRange: onPickCustomRange,
        ),
        if (entry != null && (entry.needsCustomer || entry.needsSupplier)) ...[
          const SizedBox(height: 20),
          _PartyPanel(
            viewModel: viewModel,
            entry: entry,
            onPickCustomer: onPickCustomer,
            onPickSupplier: onPickSupplier,
          ),
        ],
        const SizedBox(height: 20),
        _DetailPanel(viewModel: viewModel),
        const SizedBox(height: 20),
        _OutputActionsPanel(
          viewModel: viewModel,
          runningAction: runningAction,
          onRunAction: onRunAction,
        ),
        if (viewModel.errorMessage.isNotEmpty) ...[
          const SizedBox(height: 12),
          PointyInlineMessage.error(message: viewModel.errorMessage),
        ],
        if (entry != null && !viewModel.canRun && !viewModel.isRunning) ...[
          const SizedBox(height: 12),
          PointyInlineMessage.warning(message: l10n.reportPartyRequiredMessage),
        ],
      ],
    );
  }
}

class _SelectedReportHeader extends StatelessWidget {
  const _SelectedReportHeader({required this.viewModel});

  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final entry = viewModel.selectedEntry;
    final type = viewModel.selectedType;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(reportTitle(l10n, type), style: theme.textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(reportSubtitle(l10n, type), style: theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (entry != null)
              _DenseChip(label: reportCategoryLabel(l10n, entry.category)),
            _DenseChip(label: l10n.reportA4Chip),
            _DenseChip(label: l10n.reportAuditableChip),
            if (entry?.pointInTime ?? false)
              _DenseChip(label: l10n.reportAsOfChip),
          ],
        ),
      ],
    );
  }
}

class _PeriodPanel extends StatelessWidget {
  const _PeriodPanel({required this.viewModel, required this.onPickCustomRange});

  final ReportsViewModel viewModel;
  final Future<void> Function() onPickCustomRange;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final presets = viewModel.catalog.presets.isEmpty
        ? _fallbackPresets
        : viewModel.catalog.presets;

    return _SettingsSection(
      title: l10n.reportPeriodTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in presets)
                ChoiceChip(
                  label: Text(_presetLabel(l10n, preset)),
                  selected: viewModel.preset == preset,
                  onSelected: (_) => preset == ReportPeriodPresetOption.custom
                      ? unawaited(onPickCustomRange())
                      : viewModel.selectPreset(preset),
                ),
            ],
          ),
          if (viewModel.isCustomPeriod) ...[
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () => unawaited(onPickCustomRange()),
                icon: const Icon(Icons.date_range_outlined),
                label: Text(
                  l10n.reportDateRangeValue(
                    formatDate(viewModel.customRange.start),
                    formatDate(viewModel.customRange.end),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PartyPanel extends StatelessWidget {
  const _PartyPanel({
    required this.viewModel,
    required this.entry,
    required this.onPickCustomer,
    required this.onPickSupplier,
  });

  final ReportsViewModel viewModel;
  final ReportCatalogEntry entry;
  final Future<void> Function() onPickCustomer;
  final Future<void> Function() onPickSupplier;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isCustomer = entry.needsCustomer;
    final name = isCustomer ? viewModel.customerName : viewModel.supplierName;

    return _SettingsSection(
      title: isCustomer
          ? l10n.reportSelectCustomerLabel
          : l10n.reportSelectSupplierLabel,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          onPressed: () =>
              unawaited(isCustomer ? onPickCustomer() : onPickSupplier()),
          icon: Icon(
            isCustomer ? Icons.person_outline : Icons.local_shipping_outlined,
          ),
          label: Text(
            name.isEmpty
                ? (isCustomer
                      ? l10n.reportSelectCustomerLabel
                      : l10n.reportSelectSupplierLabel)
                : name,
          ),
        ),
      ),
    );
  }
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({required this.viewModel});

  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsSection(
          title: l10n.reportGranularityTitle,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: ReportGranularityOption.summary,
                  label: Text(l10n.reportGranularitySummary),
                ),
                ButtonSegment(
                  value: ReportGranularityOption.daily,
                  label: Text(l10n.reportGranularityDaily),
                ),
                ButtonSegment(
                  value: ReportGranularityOption.detailed,
                  label: Text(l10n.reportGranularityDetailed),
                ),
              ],
              selected: {viewModel.granularity},
              onSelectionChanged: (selection) =>
                  viewModel.selectGranularity(selection.first),
            ),
          ),
        ),
        const SizedBox(height: 20),
        _SettingsSection(
          title: l10n.reportComparisonTitle,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: ReportComparisonOption.none,
                  label: Text(l10n.reportComparisonNone),
                ),
                ButtonSegment(
                  value: ReportComparisonOption.previousPeriod,
                  label: Text(l10n.reportComparisonPreviousPeriod),
                ),
                ButtonSegment(
                  value: ReportComparisonOption.previousYear,
                  label: Text(l10n.reportComparisonPreviousYear),
                ),
              ],
              selected: {viewModel.comparison},
              onSelectionChanged: (selection) =>
                  viewModel.selectComparison(selection.first),
            ),
          ),
        ),
      ],
    );
  }
}

class _OutputActionsPanel extends StatelessWidget {
  const _OutputActionsPanel({
    required this.viewModel,
    required this.runningAction,
    required this.onRunAction,
  });

  final ReportsViewModel viewModel;
  final _ReportOutputAction? runningAction;
  final ValueChanged<_ReportOutputAction> onRunAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final busy = runningAction != null || viewModel.isRunning;
    final enabled = viewModel.canRun && !busy;

    return _SettingsSection(
      title: l10n.reportOutputTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (runningAction != null) ...[
            _ActionProgress(
              label: l10n.reportActionInProgress(
                _actionLabel(l10n, runningAction!),
              ),
            ),
            const SizedBox(height: 12),
          ],
          ResponsiveActionBar(
            actions: [
              FilledButton.icon(
                onPressed: enabled
                    ? () => onRunAction(_ReportOutputAction.run)
                    : null,
                icon: _ActionIcon(
                  icon: Icons.play_arrow_outlined,
                  isRunning: runningAction == _ReportOutputAction.run,
                ),
                label: Text(l10n.reportRunAction),
              ),
              FilledButton.tonalIcon(
                onPressed: enabled
                    ? () => onRunAction(_ReportOutputAction.previewPdf)
                    : null,
                icon: _ActionIcon(
                  icon: Icons.picture_as_pdf_outlined,
                  isRunning: runningAction == _ReportOutputAction.previewPdf,
                ),
                label: Text(l10n.reportPreviewPdfAction),
              ),
              OutlinedButton.icon(
                onPressed: enabled
                    ? () => onRunAction(_ReportOutputAction.exportCsv)
                    : null,
                icon: _ActionIcon(
                  icon: Icons.table_view_outlined,
                  isRunning: runningAction == _ReportOutputAction.exportCsv,
                ),
                label: Text(l10n.reportExportCsvAction),
              ),
              OutlinedButton.icon(
                onPressed: enabled
                    ? () => onRunAction(_ReportOutputAction.printReport)
                    : null,
                icon: _ActionIcon(
                  icon: Icons.print_outlined,
                  isRunning: runningAction == _ReportOutputAction.printReport,
                ),
                label: Text(l10n.reportPrintAction),
              ),
              OutlinedButton.icon(
                onPressed: enabled
                    ? () => onRunAction(_ReportOutputAction.exportArchive)
                    : null,
                icon: _ActionIcon(
                  icon: Icons.archive_outlined,
                  isRunning: runningAction == _ReportOutputAction.exportArchive,
                ),
                label: Text(l10n.reportExportArchiveAction),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Results and history
// ---------------------------------------------------------------------------

class _ResultArea extends StatelessWidget {
  const _ResultArea({required this.viewModel, this.onOpenDocument});

  final ReportsViewModel viewModel;
  final ValueChanged<String>? onOpenDocument;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final run = viewModel.run;

    if (viewModel.isRunning && run == null) {
      return const _SkeletonRows(count: 4);
    }
    if (run == null) {
      return PointyEmptyState(
        icon: Icons.insights_outlined,
        title: l10n.reportResultsTitle,
        message: l10n.reportResultsEmpty,
      );
    }
    return ReportResultView(
      run: run,
      isStale: !viewModel.resultMatchesSelection,
      onOpenDocument: onOpenDocument,
    );
  }
}

/// Past runs: what was issued, over what, and whether it still holds.
class _HistoryPanel extends StatefulWidget {
  const _HistoryPanel({
    required this.viewModel,
    required this.onOpen,
    required this.onVerify,
  });

  final ReportsViewModel viewModel;
  final Future<void> Function(int) onOpen;
  final Future<void> Function(int) onVerify;

  @override
  State<_HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends State<_HistoryPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final history = widget.viewModel.history;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () {
              setState(() => _expanded = !_expanded);
              if (_expanded) {
                unawaited(widget.viewModel.loadHistory());
              }
            },
            icon: Icon(
              _expanded ? Icons.expand_less : Icons.history_outlined,
            ),
            label: Text(l10n.reportHistoryTitle),
          ),
        ),
        if (_expanded) ...[
          if (widget.viewModel.isLoadingHistory)
            const _SkeletonRows(count: 3)
          else if (history.isEmpty)
            Text(l10n.reportHistoryEmpty, style: theme.textTheme.bodySmall)
          else
            for (final entry in history)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.description_outlined),
                title: Text(
                  '${entry.periodStart} — ${entry.periodEnd}',
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  [
                    formatDate(entry.createdAt),
                    if (entry.requestedByUsername != null)
                      entry.requestedByUsername!,
                    if (entry.truncated) l10n.reportTruncatedChip('—'),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
                onTap: () => unawaited(widget.onOpen(entry.id)),
                trailing: widget.viewModel.verifyingRunId == entry.id
                    ? const SizedBox.square(
                        dimension: 18,
                        child: PointySpinner(strokeWidth: 2.5),
                      )
                    : IconButton(
                        tooltip: l10n.reportHistoryVerifyAction,
                        icon: const Icon(Icons.fact_check_outlined),
                        onPressed: () => unawaited(widget.onVerify(entry.id)),
                      ),
              ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Small parts
// ---------------------------------------------------------------------------

class _ActionProgress extends StatelessWidget {
  const _ActionProgress({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 18,
          child: PointySpinner(strokeWidth: 2.5),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({required this.icon, required this.isRunning});

  final IconData icon;
  final bool isRunning;

  @override
  Widget build(BuildContext context) {
    if (!isRunning) {
      return Icon(icon);
    }
    return const SizedBox.square(
      dimension: 18,
      child: PointySpinner(strokeWidth: 2.5),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(title: title),
        const SizedBox(height: 10),
        child,
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(title, style: Theme.of(context).textTheme.titleMedium);
  }
}

class _DenseChip extends StatelessWidget {
  const _DenseChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: EdgeInsets.zero,
    );
  }
}

/// A placeholder that reads as a list while the real one loads.
class _SkeletonRows extends StatelessWidget {
  const _SkeletonRows({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var index = 0; index < count; index++)
          const PointySkeletonListTile(),
      ],
    );
  }
}

enum _ReportOutputAction {
  run,
  previewPdf,
  printReport,
  exportArchive,
  exportCsv,
}

/// Used only until the catalogue arrives, so the period control is never empty.
const _fallbackPresets = [
  ReportPeriodPresetOption.today,
  ReportPeriodPresetOption.week,
  ReportPeriodPresetOption.month,
  ReportPeriodPresetOption.lastMonth,
  ReportPeriodPresetOption.custom,
];

String _presetLabel(AppLocalizations l10n, String preset) {
  return switch (preset) {
    ReportPeriodPresetOption.today => l10n.reportPeriodToday,
    ReportPeriodPresetOption.yesterday => l10n.reportPeriodYesterday,
    ReportPeriodPresetOption.week => l10n.reportPeriodWeek,
    ReportPeriodPresetOption.month => l10n.reportPeriodMonth,
    ReportPeriodPresetOption.lastMonth => l10n.reportPeriodLastMonth,
    ReportPeriodPresetOption.quarter => l10n.reportPeriodQuarter,
    ReportPeriodPresetOption.lastQuarter => l10n.reportPeriodLastQuarter,
    ReportPeriodPresetOption.year => l10n.reportPeriodYear,
    ReportPeriodPresetOption.lastYear => l10n.reportPeriodLastYear,
    _ => l10n.reportPeriodCustom,
  };
}

String _actionLabel(AppLocalizations l10n, _ReportOutputAction action) {
  return switch (action) {
    _ReportOutputAction.run => l10n.reportRunAction,
    _ReportOutputAction.previewPdf => l10n.reportPreviewPdfAction,
    _ReportOutputAction.printReport => l10n.reportPrintAction,
    _ReportOutputAction.exportArchive => l10n.reportExportArchiveAction,
    _ReportOutputAction.exportCsv => l10n.reportExportCsvAction,
  };
}
