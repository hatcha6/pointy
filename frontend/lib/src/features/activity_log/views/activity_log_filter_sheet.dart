import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/analytics_event.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/query_controls/query_filter_sheet.dart';

class ActivityLogFilterSheet extends StatefulWidget {
  const ActivityLogFilterSheet({
    super.key,
    required this.query,
    required this.users,
  });

  final AnalyticsEventQuery query;
  final List<PosUser> users;

  @override
  State<ActivityLogFilterSheet> createState() => _ActivityLogFilterSheetState();
}

class _ActivityLogFilterSheetState extends State<ActivityLogFilterSheet> {
  late var _type = widget.query.type;
  late var _severity = widget.query.severity;
  late var _source = widget.query.source;
  late var _activityScope = widget.query.activityScope;
  late var _action = widget.query.action;
  late var _dateRange = widget.query.dateRange;
  late DateTime? _occurredAfter = widget.query.occurredAfter;
  late DateTime? _occurredBefore = widget.query.occurredBefore;
  late List<AsyncSelectionOption<int>> _selectedUsers;
  late int? _minRiskScore = widget.query.minRiskScore;
  late var _ordering = widget.query.ordering;
  late final TextEditingController _sessionController;
  late final TextEditingController _entityTypeController;
  late final TextEditingController _entityIdController;

  @override
  void initState() {
    super.initState();
    _selectedUsers = _selectedUserOptionsFromQuery(widget.query, widget.users);
    _sessionController = TextEditingController(
      text: widget.query.registerSessionId,
    );
    _entityTypeController = TextEditingController(
      text: widget.query.entityType,
    );
    _entityIdController = TextEditingController(text: widget.query.entityId);
  }

  @override
  void dispose() {
    _sessionController.dispose();
    _entityTypeController.dispose();
    _entityIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryFilterSheet(
      title: l10n.filtersSheetTitle,
      resetLabel: l10n.resetFiltersButton,
      applyLabel: l10n.applyFiltersButton,
      onReset: _reset,
      onApply: _apply,
      children: [
        const SizedBox(height: 22),
        QueryFilterSection(
          title: l10n.activityLogScopeFilterTitle,
          children: [
            for (final scope in AnalyticsEventActivityScope.values)
              QueryFilterOptionTile(
                label: activityScopeFilterLabel(l10n, scope),
                icon: _activityScopeIcon(scope),
                isSelected: _activityScope == scope,
                onTap: () => setState(() => _activityScope = scope),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.activityLogActionFilterTitle,
          children: [
            for (final action in AnalyticsEventActionFilter.values)
              QueryFilterOptionTile(
                label: activityActionFilterLabel(l10n, action),
                icon: _actionIcon(action),
                isSelected: _action == action,
                onTap: () => setState(() => _action = action),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.activityLogDateFilterTitle,
          children: [
            for (final range in AnalyticsEventDateRange.values)
              QueryFilterOptionTile(
                label: activityDateRangeLabel(l10n, range),
                icon: _dateRangeIcon(range),
                isSelected: _dateRange == range,
                onTap: () => setState(() => _dateRange = range),
              ),
            if (_dateRange == AnalyticsEventDateRange.custom)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickDate(isStart: true),
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text(
                          _occurredAfter == null
                              ? l10n.activityLogFromDateOpen
                              : l10n.activityLogFromDateValue(
                                  formatDate(_occurredAfter!),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickDate(isStart: false),
                        icon: const Icon(Icons.event_available_outlined),
                        label: Text(
                          _occurredBefore == null
                              ? l10n.activityLogToDateOpen
                              : l10n.activityLogToDateValue(
                                  formatDate(
                                    _occurredBefore!.subtract(
                                      const Duration(microseconds: 1),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.activityLogUserFilterTitle,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: AsyncSelectionField<int>(
                fieldKey: const ValueKey('activity_log_user_filter_field'),
                strings: activityLogUserFieldStrings(l10n),
                selected: _selectedUsers,
                onPick: () => _pickUsers(context),
                onClear: _selectedUsers.isEmpty
                    ? null
                    : () => setState(() => _selectedUsers = []),
                validator: (_) => null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.activityLogContextFilterTitle,
          children: [
            _TextFilterField(
              controller: _sessionController,
              label: l10n.activityLogSessionFilterLabel,
              icon: Icons.point_of_sale_outlined,
            ),
            _TextFilterField(
              controller: _entityTypeController,
              label: l10n.activityLogEntityTypeFilterLabel,
              icon: Icons.category_outlined,
            ),
            _TextFilterField(
              controller: _entityIdController,
              label: l10n.activityLogEntityIdFilterLabel,
              icon: Icons.tag_outlined,
            ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.activityLogEventTypeFilterTitle,
          children: [
            for (final type in AnalyticsEventTypeFilter.values)
              QueryFilterOptionTile(
                label: activityTypeFilterLabel(l10n, type),
                icon: _typeIcon(type),
                isSelected: _type == type,
                onTap: () => setState(() => _type = type),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.activityLogSeverityFilterTitle,
          children: [
            for (final severity in AnalyticsEventSeverityFilter.values)
              QueryFilterOptionTile(
                label: activitySeverityFilterLabel(l10n, severity),
                icon: _severityIcon(severity),
                isSelected: _severity == severity,
                onTap: () => setState(() => _severity = severity),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.activityLogRiskFilterTitle,
          children: [
            for (final score in const <int?>[null, 50, 70, 90])
              QueryFilterOptionTile(
                label: score == null
                    ? l10n.activityLogRiskAll
                    : l10n.activityLogRiskAtLeast(score),
                icon: score == null
                    ? Icons.shield_outlined
                    : Icons.gpp_maybe_outlined,
                isSelected: _minRiskScore == score,
                onTap: () => setState(() => _minRiskScore = score),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.activityLogSourceFilterTitle,
          children: [
            for (final source in AnalyticsEventSourceFilter.values)
              QueryFilterOptionTile(
                label: activitySourceFilterLabel(l10n, source),
                icon: _sourceIcon(source),
                isSelected: _source == source,
                onTap: () => setState(() => _source = source),
              ),
          ],
        ),
        const SizedBox(height: 18),
        QueryFilterSection(
          title: l10n.activityLogOrderingTitle,
          children: [
            for (final ordering in AnalyticsEventOrdering.values)
              QueryFilterOptionTile(
                label: activityOrderingLabel(l10n, ordering),
                icon: _orderingIcon(ordering),
                isSelected: _ordering == ordering,
                onTap: () => setState(() => _ordering = ordering),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickDate({required bool isStart}) async {
    final current = isStart ? _occurredAfter : _occurredBefore;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _dateRange = AnalyticsEventDateRange.custom;
      if (isStart) {
        _occurredAfter = DateTime(picked.year, picked.month, picked.day);
      } else {
        _occurredBefore = DateTime(
          picked.year,
          picked.month,
          picked.day,
        ).add(const Duration(days: 1));
      }
    });
  }

  void _reset() {
    setState(() {
      _type = AnalyticsEventTypeFilter.all;
      _severity = AnalyticsEventSeverityFilter.all;
      _source = AnalyticsEventSourceFilter.all;
      _activityScope = AnalyticsEventActivityScope.reviewable;
      _action = AnalyticsEventActionFilter.all;
      _dateRange = AnalyticsEventDateRange.last7Days;
      _occurredAfter = null;
      _occurredBefore = null;
      _selectedUsers = [];
      _sessionController.clear();
      _entityTypeController.clear();
      _entityIdController.clear();
      _minRiskScore = null;
      _ordering = AnalyticsEventOrdering.newest;
    });
  }

  void _apply() {
    Navigator.of(context).pop(
      widget.query.copyWith(
        type: _type,
        severity: _severity,
        source: _source,
        activityScope: _activityScope,
        action: _action,
        dateRange: _dateRange,
        occurredAfter: _occurredAfter,
        occurredBefore: _occurredBefore,
        clearOccurredAfter: _occurredAfter == null,
        clearOccurredBefore: _occurredBefore == null,
        userIds: [for (final user in _selectedUsers) user.id],
        userLabels: [for (final user in _selectedUsers) user.label],
        clearUser: _selectedUsers.isEmpty,
        registerSessionId: _sessionController.text,
        entityType: _entityTypeController.text,
        entityId: _entityIdController.text,
        minRiskScore: _minRiskScore,
        clearMinRiskScore: _minRiskScore == null,
        ordering: _ordering,
      ),
    );
  }

  Future<void> _pickUsers(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: activityLogUserPickerStrings(l10n),
      selected: _selectedUsers,
      searchFieldKey: const ValueKey('activity_log_user_filter_search_field'),
      applyButtonKey: const ValueKey('activity_log_user_filter_apply_button'),
      optionKeyForId: (id) => ValueKey('activity_log_user_filter_option_$id'),
      loadPage: _loadUserSelectionPage,
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedUsers = picked);
  }

  Future<AsyncSelectionPage<int>> _loadUserSelectionPage(
    String search,
    int page,
  ) async {
    const pageSize = 24;
    final normalizedSearch = search.trim().toLowerCase();
    final users = [
      for (final user in widget.users)
        if (_matchesUserSearch(user, normalizedSearch)) user,
    ];
    final start = (page - 1) * pageSize;
    if (start >= users.length) {
      return const AsyncSelectionPage<int>(options: [], hasMore: false);
    }
    final end = start + pageSize > users.length
        ? users.length
        : start + pageSize;
    return AsyncSelectionPage<int>(
      options: [for (final user in users.sublist(start, end)) userOption(user)],
      hasMore: end < users.length,
    );
  }
}

AsyncSelectionFieldStrings<int> activityLogUserFieldStrings(
  AppLocalizations l10n,
) {
  return AsyncSelectionFieldStrings<int>(
    label: l10n.activityLogUserFilterLabel,
    emptyText: l10n.activityLogAllUsers,
    helperText: l10n.activityLogUserFilterHelper,
    clearTooltip: l10n.clearButton,
    openPickerTooltip: l10n.activityLogUsersOpenPickerTooltip,
    fallbackLabelForId: l10n.activityLogUserFallbackLabel,
  );
}

AsyncSelectionPickerStrings<int> activityLogUserPickerStrings(
  AppLocalizations l10n,
) {
  return AsyncSelectionPickerStrings<int>(
    title: l10n.activityLogUserPickerTitle,
    searchHint: l10n.activityLogUserPickerSearchHint,
    emptyText: l10n.activityLogUserPickerEmpty,
    clearText: l10n.clearButton,
    clearSearchTooltip: l10n.clearSearchTooltip,
    loadErrorText: l10n.activityLogUserPickerLoadError,
    confirmText: l10n.confirmButton,
    fallbackLabelForId: l10n.activityLogUserFallbackLabel,
  );
}

AsyncSelectionOption<int> userOption(PosUser user) {
  final subtitleParts = [
    if (user.username.trim().isNotEmpty && user.username != user.label)
      user.username,
    if (user.email.trim().isNotEmpty) user.email,
  ];
  return AsyncSelectionOption<int>(
    id: user.id,
    label: user.label,
    subtitle: subtitleParts.join(' - '),
  );
}

List<AsyncSelectionOption<int>> _selectedUserOptionsFromQuery(
  AnalyticsEventQuery query,
  List<PosUser> users,
) {
  final usersById = {for (final user in users) user.id: user};
  final userIds = query.selectedUserIds;
  final userLabels = query.selectedUserLabels;
  return [
    for (final (index, id) in userIds.indexed)
      if (usersById[id] case final user?)
        userOption(user)
      else
        AsyncSelectionOption<int>(
          id: id,
          label: index < userLabels.length ? userLabels[index] : '',
          subtitle: '',
        ),
  ];
}

bool _matchesUserSearch(PosUser user, String search) {
  if (search.isEmpty) {
    return true;
  }
  return user.label.toLowerCase().contains(search) ||
      user.username.toLowerCase().contains(search) ||
      user.email.toLowerCase().contains(search);
}

class _TextFilterField extends StatelessWidget {
  const _TextFilterField({
    required this.controller,
    required this.label,
    required this.icon,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          prefixIcon: Icon(icon),
        ),
      ),
    );
  }
}

String activityScopeFilterLabel(
  AppLocalizations l10n,
  AnalyticsEventActivityScope scope,
) {
  return switch (scope) {
    AnalyticsEventActivityScope.reviewable => l10n.activityScopeReviewable,
    AnalyticsEventActivityScope.all => l10n.activityScopeAll,
    AnalyticsEventActivityScope.technical => l10n.activityScopeTechnical,
  };
}

String activityActionFilterLabel(
  AppLocalizations l10n,
  AnalyticsEventActionFilter action,
) {
  return switch (action) {
    AnalyticsEventActionFilter.all => l10n.activityActionAll,
    AnalyticsEventActionFilter.fraudSignal => l10n.activityActionFraudSignal,
    AnalyticsEventActionFilter.posLineAdded => l10n.activityActionPosLineAdded,
    AnalyticsEventActionFilter.posLineDeleted =>
      l10n.activityActionPosLineDeleted,
    AnalyticsEventActionFilter.posLineQuantityChanged =>
      l10n.activityActionPosLineQuantityChanged,
    AnalyticsEventActionFilter.posCartCleared =>
      l10n.activityActionPosCartCleared,
    AnalyticsEventActionFilter.purchaseLineAdded =>
      l10n.activityActionPurchaseLineAdded,
    AnalyticsEventActionFilter.purchaseLineDeleted =>
      l10n.activityActionPurchaseLineDeleted,
    AnalyticsEventActionFilter.purchaseLineQuantityChanged =>
      l10n.activityActionPurchaseLineQuantityChanged,
    AnalyticsEventActionFilter.purchaseDraftCleared =>
      l10n.activityActionPurchaseDraftCleared,
    AnalyticsEventActionFilter.purchaseDraftSubmitted =>
      l10n.activityActionPurchaseDraftSubmitted,
    AnalyticsEventActionFilter.invoiceCreated =>
      l10n.activityActionInvoiceCreated,
    AnalyticsEventActionFilter.customerCreated =>
      l10n.activityActionCustomerCreated,
    AnalyticsEventActionFilter.registerCashMovement =>
      l10n.activityActionRegisterCashMovement,
    AnalyticsEventActionFilter.registerSessionStarted =>
      l10n.activityActionRegisterSessionStarted,
    AnalyticsEventActionFilter.registerSessionClosed =>
      l10n.activityActionRegisterSessionClosed,
    AnalyticsEventActionFilter.receiptReprinted =>
      l10n.activityActionReceiptReprinted,
    AnalyticsEventActionFilter.orderVoided => l10n.activityActionOrderVoided,
    AnalyticsEventActionFilter.orderReturned =>
      l10n.activityActionOrderReturned,
    AnalyticsEventActionFilter.productChanged =>
      l10n.activityActionProductChanged,
    AnalyticsEventActionFilter.stockMovementCreated =>
      l10n.activityActionStockMovementCreated,
    AnalyticsEventActionFilter.barcodeLabelsPrinted =>
      l10n.activityActionBarcodeLabelsPrinted,
    AnalyticsEventActionFilter.userChanged => l10n.activityActionUserChanged,
    AnalyticsEventActionFilter.settingsChanged =>
      l10n.activityActionSettingsChanged,
    AnalyticsEventActionFilter.discountChanged =>
      l10n.activityActionDiscountChanged,
    AnalyticsEventActionFilter.reportActivity =>
      l10n.activityActionReportActivity,
    AnalyticsEventActionFilter.printerActivity =>
      l10n.activityActionPrinterActivity,
    AnalyticsEventActionFilter.analyticsExport =>
      l10n.activityActionAnalyticsExport,
    AnalyticsEventActionFilter.purchaseOrderDeleted =>
      l10n.activityActionPurchaseOrderDeleted,
    AnalyticsEventActionFilter.anyDeleted => l10n.activityActionAnyDeleted,
  };
}

String activityDateRangeLabel(
  AppLocalizations l10n,
  AnalyticsEventDateRange range,
) {
  return switch (range) {
    AnalyticsEventDateRange.all => l10n.activityDateRangeAll,
    AnalyticsEventDateRange.today => l10n.activityDateRangeToday,
    AnalyticsEventDateRange.last7Days => l10n.activityDateRange7Days,
    AnalyticsEventDateRange.last30Days => l10n.activityDateRange30Days,
    AnalyticsEventDateRange.custom => l10n.activityDateRangeCustom,
  };
}

String activityTypeFilterLabel(
  AppLocalizations l10n,
  AnalyticsEventTypeFilter type,
) {
  return switch (type) {
    AnalyticsEventTypeFilter.all => l10n.analyticsExportAnyValue,
    AnalyticsEventTypeFilter.audit => l10n.analyticsEventTypeAudit,
    AnalyticsEventTypeFilter.fraudSignal => l10n.analyticsEventTypeFraudSignal,
    AnalyticsEventTypeFilter.security => l10n.analyticsEventTypeSecurity,
    AnalyticsEventTypeFilter.error => l10n.analyticsEventTypeError,
    AnalyticsEventTypeFilter.performance => l10n.analyticsEventTypePerformance,
    AnalyticsEventTypeFilter.usage => l10n.analyticsEventTypeUsage,
  };
}

String activitySeverityFilterLabel(
  AppLocalizations l10n,
  AnalyticsEventSeverityFilter severity,
) {
  return switch (severity) {
    AnalyticsEventSeverityFilter.all => l10n.analyticsExportAnyValue,
    AnalyticsEventSeverityFilter.warning => l10n.analyticsSeverityWarning,
    AnalyticsEventSeverityFilter.error => l10n.analyticsSeverityError,
    AnalyticsEventSeverityFilter.critical => l10n.analyticsSeverityCritical,
    AnalyticsEventSeverityFilter.info => l10n.analyticsSeverityInfo,
    AnalyticsEventSeverityFilter.debug => l10n.analyticsSeverityDebug,
  };
}

String activitySourceFilterLabel(
  AppLocalizations l10n,
  AnalyticsEventSourceFilter source,
) {
  return switch (source) {
    AnalyticsEventSourceFilter.all => l10n.analyticsExportAnyValue,
    AnalyticsEventSourceFilter.backend => l10n.analyticsSourceBackend,
    AnalyticsEventSourceFilter.frontend => l10n.analyticsSourceFrontend,
    AnalyticsEventSourceFilter.printAgent => l10n.analyticsSourcePrintAgent,
    AnalyticsEventSourceFilter.integration => l10n.analyticsSourceIntegration,
  };
}

String activityOrderingLabel(
  AppLocalizations l10n,
  AnalyticsEventOrdering ordering,
) {
  return switch (ordering) {
    AnalyticsEventOrdering.newest => l10n.activityOrderingNewest,
    AnalyticsEventOrdering.oldest => l10n.activityOrderingOldest,
    AnalyticsEventOrdering.highestRisk => l10n.activityOrderingHighestRisk,
    AnalyticsEventOrdering.newestReceived =>
      l10n.activityOrderingNewestReceived,
  };
}

IconData _activityScopeIcon(AnalyticsEventActivityScope scope) {
  return switch (scope) {
    AnalyticsEventActivityScope.reviewable => Icons.fact_check_outlined,
    AnalyticsEventActivityScope.all => Icons.all_inbox_outlined,
    AnalyticsEventActivityScope.technical => Icons.memory_outlined,
  };
}

IconData _actionIcon(AnalyticsEventActionFilter action) {
  return switch (action) {
    AnalyticsEventActionFilter.all => Icons.manage_search_outlined,
    AnalyticsEventActionFilter.fraudSignal => Icons.gpp_maybe_outlined,
    AnalyticsEventActionFilter.posLineAdded => Icons.add_shopping_cart_outlined,
    AnalyticsEventActionFilter.posLineDeleted =>
      Icons.remove_shopping_cart_outlined,
    AnalyticsEventActionFilter.posLineQuantityChanged =>
      Icons.exposure_outlined,
    AnalyticsEventActionFilter.posCartCleared =>
      Icons.remove_shopping_cart_outlined,
    AnalyticsEventActionFilter.purchaseLineAdded => Icons.add_circle_outline,
    AnalyticsEventActionFilter.purchaseLineDeleted =>
      Icons.remove_circle_outline,
    AnalyticsEventActionFilter.purchaseLineQuantityChanged =>
      Icons.exposure_outlined,
    AnalyticsEventActionFilter.purchaseDraftCleared =>
      Icons.delete_sweep_outlined,
    AnalyticsEventActionFilter.purchaseDraftSubmitted =>
      Icons.assignment_turned_in_outlined,
    AnalyticsEventActionFilter.invoiceCreated => Icons.receipt_long_outlined,
    AnalyticsEventActionFilter.customerCreated => Icons.person_add_alt_1,
    AnalyticsEventActionFilter.registerCashMovement =>
      Icons.account_balance_wallet_outlined,
    AnalyticsEventActionFilter.registerSessionStarted =>
      Icons.point_of_sale_outlined,
    AnalyticsEventActionFilter.registerSessionClosed =>
      Icons.lock_clock_outlined,
    AnalyticsEventActionFilter.receiptReprinted => Icons.print_outlined,
    AnalyticsEventActionFilter.orderVoided => Icons.block_outlined,
    AnalyticsEventActionFilter.orderReturned => Icons.keyboard_return_outlined,
    AnalyticsEventActionFilter.productChanged => Icons.inventory_2_outlined,
    AnalyticsEventActionFilter.stockMovementCreated => Icons.move_down_outlined,
    AnalyticsEventActionFilter.barcodeLabelsPrinted => Icons.qr_code_2,
    AnalyticsEventActionFilter.userChanged => Icons.manage_accounts_outlined,
    AnalyticsEventActionFilter.settingsChanged => Icons.settings_outlined,
    AnalyticsEventActionFilter.discountChanged => Icons.percent_outlined,
    AnalyticsEventActionFilter.reportActivity => Icons.assessment_outlined,
    AnalyticsEventActionFilter.printerActivity => Icons.print_outlined,
    AnalyticsEventActionFilter.analyticsExport => Icons.file_download_outlined,
    AnalyticsEventActionFilter.purchaseOrderDeleted =>
      Icons.delete_sweep_outlined,
    AnalyticsEventActionFilter.anyDeleted => Icons.delete_outline,
  };
}

IconData _dateRangeIcon(AnalyticsEventDateRange range) {
  return switch (range) {
    AnalyticsEventDateRange.all => Icons.all_inclusive,
    AnalyticsEventDateRange.today => Icons.today_outlined,
    AnalyticsEventDateRange.last7Days => Icons.date_range_outlined,
    AnalyticsEventDateRange.last30Days => Icons.calendar_month_outlined,
    AnalyticsEventDateRange.custom => Icons.edit_calendar_outlined,
  };
}

IconData _typeIcon(AnalyticsEventTypeFilter type) {
  return switch (type) {
    AnalyticsEventTypeFilter.all => Icons.all_inbox_outlined,
    AnalyticsEventTypeFilter.audit => Icons.fact_check_outlined,
    AnalyticsEventTypeFilter.fraudSignal => Icons.gpp_maybe_outlined,
    AnalyticsEventTypeFilter.security => Icons.security_outlined,
    AnalyticsEventTypeFilter.error => Icons.error_outline,
    AnalyticsEventTypeFilter.performance => Icons.speed_outlined,
    AnalyticsEventTypeFilter.usage => Icons.ads_click_outlined,
  };
}

IconData _severityIcon(AnalyticsEventSeverityFilter severity) {
  return switch (severity) {
    AnalyticsEventSeverityFilter.all => Icons.flag_outlined,
    AnalyticsEventSeverityFilter.debug => Icons.bug_report_outlined,
    AnalyticsEventSeverityFilter.info => Icons.info_outline,
    AnalyticsEventSeverityFilter.warning => Icons.warning_amber_outlined,
    AnalyticsEventSeverityFilter.error => Icons.error_outline,
    AnalyticsEventSeverityFilter.critical => Icons.priority_high,
  };
}

IconData _sourceIcon(AnalyticsEventSourceFilter source) {
  return switch (source) {
    AnalyticsEventSourceFilter.all => Icons.hub_outlined,
    AnalyticsEventSourceFilter.backend => Icons.dns_outlined,
    AnalyticsEventSourceFilter.frontend => Icons.web_asset_outlined,
    AnalyticsEventSourceFilter.printAgent => Icons.print_outlined,
    AnalyticsEventSourceFilter.integration => Icons.extension_outlined,
  };
}

IconData _orderingIcon(AnalyticsEventOrdering ordering) {
  return switch (ordering) {
    AnalyticsEventOrdering.newest => Icons.schedule_outlined,
    AnalyticsEventOrdering.oldest => Icons.history_outlined,
    AnalyticsEventOrdering.highestRisk => Icons.shield_outlined,
    AnalyticsEventOrdering.newestReceived => Icons.cloud_done_outlined,
  };
}
