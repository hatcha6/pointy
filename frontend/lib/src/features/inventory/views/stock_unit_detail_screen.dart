import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/consignment.dart';
import '../../../data/models/stock_unit.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/tracked_stock_view_model.dart';
import 'consignment_incident_sheet.dart';

/// One article of stock, and what became of it.
///
/// The page a warranty claim, an insurance claim or a police question is
/// answered from — which is why the timeline underneath is allocations rather
/// than a free-text note, and why nothing on it is editable except the three
/// things a person legitimately changes about an article without moving it: its
/// asking price, its condition, and what somebody wrote about it.
class StockUnitDetailScreen extends StatefulWidget {
  const StockUnitDetailScreen({
    super.key,
    required this.viewModel,
    required this.unit,
    required this.capabilities,
  });

  final TrackedStockViewModel viewModel;
  final StockUnit unit;
  final AuthorizationCapabilities capabilities;

  @override
  State<StockUnitDetailScreen> createState() => _StockUnitDetailScreenState();
}

class _StockUnitDetailScreenState extends State<StockUnitDetailScreen> {
  late StockUnit _unit = widget.unit;
  List<StockAllocationEntry> _history = const [];

  /// `allocations ∪ events` (§6.9). Loaded beside the allocations rather than
  /// instead of them: an older backend answers 404 here and the screen still
  /// renders the movements, which is the half that matters most.
  List<StockUnitTimelineEntry> _timelineEntries = const [];
  List<ConsignmentIncident> _incidents = const [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final history = await widget.viewModel.unitHistory(_unit.id);
    final fresh = await widget.viewModel.unitById(_unit.id);
    final timeline = await widget.viewModel.unitTimeline(_unit.id);
    final incidents = widget.unit.isConsignment
        ? await widget.viewModel.unitIncidents(_unit.id)
        : const <ConsignmentIncident>[];
    if (!mounted) {
      return;
    }
    setState(() {
      _history = history;
      _timelineEntries = timeline;
      _incidents = incidents;
      _unit = fresh ?? _unit;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return PointyScaffold(
      appBar: PointyAppBar(
        title: Text(
          _unit.isIdentified ? _unit.code : l10n.stockUnitsAwaitingIdentifier,
        ),
        isLoading: _isLoading,
        actions: [
          IconButton(
            tooltip: l10n.refreshShopSettingsTooltip,
            onPressed: _reload,
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: ListView(
        padding: spacing.pagePadding,
        children: [
          _hero(context, l10n),
          const SizedBox(height: 16),
          if (_unit.isConsignment) ...[
            _consignmentPanel(context, l10n),
            const SizedBox(height: 16),
          ],
          _facts(context, l10n),
          const SizedBox(height: 16),
          if (_unit.attributes.isNotEmpty) ...[
            _attributes(context, l10n),
            const SizedBox(height: 16),
          ],
          _actions(context, l10n),
          const SizedBox(height: 16),
          _incidentsSection(context, l10n),
          if (_incidents.isNotEmpty) const SizedBox(height: 16),
          _timeline(context, l10n),
        ],
      ),
    );
  }

  Widget _hero(BuildContext context, AppLocalizations l10n) {
    final colors = context.pointyColors;
    return PointyDetailHero(
      icon: _unit.isConsignment
          ? Icons.handshake_outlined
          : Icons.qr_code_2_outlined,
      title: _unit.productName.isNotEmpty
          ? _unit.productName
          : _unit.variantName,
      value: formatMoney(_unit.listPrice ?? _unit.soldPrice ?? 0),
      valueSubtitle: _unit.listPrice != null
          ? l10n.stockUnitOwnPrice
          : l10n.stockUnitVariantPrice,
      description: _unit.isIdentified ? _unit.code : null,
      pills: [
        PointyHeroPill(label: _statusLabel(l10n, _unit.status)),
        if (_unit.isConsignment)
          PointyHeroPill(label: l10n.stockUnitConsignmentBadge),
        if (_unit.isUnderWarranty && _unit.warrantyExpiresOn != null)
          PointyHeroPill(
            label: l10n.stockUnitWarrantyUntil(
              formatDate(_unit.warrantyExpiresOn!),
            ),
          ),
        if (_unit.batchCode.isNotEmpty)
          PointyHeroPill(label: l10n.posCartLineBatchBadge(_unit.batchCode)),
      ],
      gradientColors: _unit.isConsignment
          ? [colors.accentAmber, colors.primaryDark]
          : null,
    );
  }

  Widget _consignmentPanel(BuildContext context, AppLocalizations l10n) {
    final l10nRows = <PointySummaryRow>[
      PointySummaryRow(
        label: l10n.stockUnitConsignor,
        value: _unit.consignorName.isEmpty ? '—' : _unit.consignorName,
      ),
      if (_unit.declaredValue != null)
        PointySummaryRow(
          label: l10n.stockUnitDeclaredValue,
          value: formatMoney(_unit.declaredValue!),
        ),
      if (_unit.awaitsPayout)
        PointySummaryRow(
          label: l10n.stockUnitPayoutOwed,
          value: formatMoney(_unit.incomingRate ?? 0),
          emphasized: true,
          dividerAbove: true,
        ),
      if (_unit.consignorPaidAt != null)
        PointySummaryRow(
          label: l10n.stockUnitPayoutPaidOn,
          value: formatDate(_unit.consignorPaidAt!),
        ),
    ];
    return PointyDetailSection(
      title: l10n.stockUnitConsignmentSection,
      icon: Icons.handshake_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointySummaryList(rows: l10nRows),
          if (_unit.awaitsPayout)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _resendSms,
                icon: const Icon(Icons.sms_outlined),
                label: Text(l10n.consignmentResendSms),
              ),
            ),
        ],
      ),
    );
  }

  Widget _facts(BuildContext context, AppLocalizations l10n) {
    return PointyDetailSection(
      title: l10n.stockUnitFactsSection,
      icon: Icons.info_outline,
      child: PointySummaryList(
        rows: [
          PointySummaryRow(
            label: l10n.stockUnitWarehouse,
            value: _unit.warehouseName.isEmpty ? '—' : _unit.warehouseName,
          ),
          if (_unit.daysInStock != null && _unit.isOnHand)
            PointySummaryRow(
              label: l10n.stockUnitDaysHeld,
              value: '${_unit.daysInStock}',
            ),
          // Cost is absent, not null, for a reader without the permission — so
          // the rows simply are not built rather than showing a blank.
          if (_unit.showsCost)
            PointySummaryRow(
              label: l10n.stockUnitCost,
              value: formatMoney(_unit.incomingRate ?? 0),
            ),
          if (_unit.showsCost && (_unit.refurbCost ?? 0) > 0)
            PointySummaryRow(
              label: l10n.stockUnitRefurbCost,
              value: formatMoney(_unit.refurbCost!),
            ),
          if (_unit.showsCost)
            PointySummaryRow(
              label: l10n.stockUnitTotalCost,
              value: formatMoney(_unit.totalCost ?? 0),
              emphasized: true,
              dividerAbove: true,
            ),
          if (_unit.soldAt != null)
            PointySummaryRow(
              label: l10n.stockUnitSoldOn,
              value: formatDate(_unit.soldAt!),
            ),
          if (_unit.soldPrice != null)
            PointySummaryRow(
              label: l10n.stockUnitSoldFor,
              value: formatMoney(_unit.soldPrice!),
            ),
        ],
      ),
    );
  }

  Widget _attributes(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return PointyDetailSection(
      title: l10n.stockUnitAttributesSection,
      icon: Icons.tune_outlined,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in _unit.attributes.entries)
            Chip(
              label: Text('${entry.key}: ${entry.value}'),
              labelStyle: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context, AppLocalizations l10n) {
    final canReprice = widget.capabilities.canRepriceStockUnit;
    // §6.8: a consigned article is never written off through this button. Its
    // own rate is zero, so the action would move no money and record no
    // claim, and a shop that lost somebody else's camera would have written
    // off a liability by filling in a reason box. The backend refuses it too;
    // hiding it here is so nobody is offered the wrong door.
    final canWriteOff =
        widget.capabilities.canWriteOffStockUnit && !_unit.isConsignment;
    final canReportIncident =
        widget.capabilities.canManageConsignmentIncident && _unit.isConsignment;
    if (!canReprice && !canWriteOff && !canReportIncident) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (canReprice && _unit.isOnHand)
          OutlinedButton.icon(
            onPressed: _reprice,
            icon: const Icon(Icons.sell_outlined),
            label: Text(l10n.stockUnitRepriceAction),
          ),
        if (canWriteOff && _unit.isOnHand)
          OutlinedButton.icon(
            onPressed: _writeOff,
            icon: const Icon(Icons.delete_outline),
            label: Text(l10n.stockUnitWriteOffAction),
          ),
        if (canReportIncident)
          OutlinedButton.icon(
            onPressed: _reportIncident,
            icon: const Icon(Icons.report_gmailerrorred_outlined),
            label: Text(l10n.custodyIncidentReport),
          ),
      ],
    );
  }

  /// Everything that has ever happened to this article in our care (§6.2.2).
  Widget _incidentsSection(BuildContext context, AppLocalizations l10n) {
    if (_incidents.isEmpty) {
      return const SizedBox.shrink();
    }
    return PointyDetailSection(
      title: l10n.custodyIncidentsTitle,
      icon: Icons.report_gmailerrorred_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final incident in _incidents)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined, size: 18),
              title: Text(
                '${incident.number} · '
                '${consignmentIncidentKindLabel(l10n, incident.kind)}',
              ),
              subtitle: Text(
                [
                  consignmentResponsibilityLabel(l10n, incident.responsibility),
                  consignmentResolutionLabel(l10n, incident.resolution),
                  if (!incident.isAssessed && incident.isOpen)
                    l10n.custodyIncidentUnassessed,
                ].join(' · '),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _reportIncident() async {
    final messenger = ScaffoldMessenger.of(context);
    final draft = await showConsignmentIncidentSheet(context);
    if (draft == null || !mounted) {
      return;
    }
    final error = await widget.viewModel.reportIncident(_unit.id, draft);
    if (!mounted) {
      return;
    }
    if (error != null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    await _reload();
  }

  Widget _timeline(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return PointyDetailSection(
      title: l10n.stockUnitTimelineSection,
      icon: Icons.timeline_outlined,
      child: _history.isEmpty
          ? Text(
              l10n.stockUnitHistoryEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in _history)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      entry.isIncoming
                          ? Icons.south_west_outlined
                          : Icons.north_east_outlined,
                      size: 18,
                    ),
                    title: Text(entry.voucherType),
                    subtitle: Text(
                      [
                        if (entry.postingAt != null)
                          formatDateTime(entry.postingAt!),
                        if (entry.warehouseName.isNotEmpty) entry.warehouseName,
                      ].join(' · '),
                    ),
                  ),
                // The things that happened to it and moved no stock (§6.9):
                // who dropped its price, who scanned it in a count, which
                // incident it is part of.
                for (final entry in _timelineEntries.where(
                  (row) => !row.isAllocation,
                ))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.edit_note_outlined, size: 18),
                    title: Text(_eventLabel(l10n, entry.kind)),
                    subtitle: Text(
                      [
                        formatDateTime(entry.at),
                        if (entry.actorName.isNotEmpty) entry.actorName,
                        if (entry.note.isNotEmpty) entry.note,
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
    );
  }

  static String _eventLabel(AppLocalizations l10n, String kind) {
    return switch (kind) {
      'repriced' => l10n.unitTimelineEventRepriced,
      'identified' => l10n.unitTimelineEventIdentified,
      'written_off' => l10n.unitTimelineEventWrittenOff,
      'incident' => l10n.unitTimelineEventIncident,
      'counted' => l10n.unitTimelineEventCounted,
      'relocated' => l10n.unitTimelineEventRelocated,
      _ => kind,
    };
  }

  Future<void> _reprice() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController(
      text: _unit.listPrice?.toStringAsFixed(2) ?? '',
    );
    final price = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.stockUnitRepriceAction),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: l10n.stockUnitOwnPrice),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              context,
            ).pop(double.tryParse(controller.text.trim())),
            child: Text(l10n.saveButton),
          ),
        ],
      ),
    );
    if (price == null) {
      return;
    }
    final updated = await widget.viewModel.reprice(_unit.id, price);
    if (!mounted) {
      return;
    }
    if (updated == null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.stockUnitRepriceFailed)));
      return;
    }
    setState(() => _unit = updated);
  }

  Future<void> _writeOff() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.stockUnitWriteOffAction),
        // Stock leaves, so the reason is part of the record rather than a
        // courtesy: "written off" with no sentence beside it is the finding
        // nobody can explain six months later.
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: l10n.stockUnitWriteOffReason),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(l10n.stockUnitWriteOffAction),
          ),
        ],
      ),
    );
    if (reason == null || reason.isEmpty) {
      return;
    }
    final updated = await widget.viewModel.writeOff(_unit.id, reason);
    if (!mounted) {
      return;
    }
    if (updated == null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.stockUnitWriteOffFailed)));
      return;
    }
    setState(() => _unit = updated);
  }

  Future<void> _resendSms() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final queued = await widget.viewModel.resendConsignorSms(_unit.id);
    if (!mounted) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            queued ? l10n.consignmentSmsQueued : l10n.consignmentSmsFailed,
          ),
        ),
      );
  }

  String _statusLabel(AppLocalizations l10n, String status) {
    return switch (status) {
      StockUnitStatus.inStock => l10n.stockUnitStatusInStock,
      StockUnitStatus.reserved => l10n.stockUnitStatusReserved,
      StockUnitStatus.sold => l10n.stockUnitStatusSold,
      StockUnitStatus.damaged => l10n.stockUnitStatusDamaged,
      StockUnitStatus.writtenOff => l10n.stockUnitStatusWrittenOff,
      _ => status,
    };
  }
}
