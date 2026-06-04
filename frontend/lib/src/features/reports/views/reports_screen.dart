import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';

typedef ReportActionCallback = Future<void> Function(ReportRequest request);

enum ReportType {
  salesSummary,
  registerSessions,
  payments,
  inventoryValue,
  stockMovement,
  purchases,
}

enum ReportPeriodPreset { today, week, month, custom }

enum ReportGranularity { summary, daily, detailed }

class ReportRequest {
  const ReportRequest({
    required this.type,
    required this.periodPreset,
    required this.dateRange,
    required this.granularity,
    required this.includeAuditTrail,
    required this.includePreparedBy,
  });

  final ReportType type;
  final ReportPeriodPreset periodPreset;
  final DateTimeRange dateRange;
  final ReportGranularity granularity;
  final bool includeAuditTrail;
  final bool includePreparedBy;
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenDiscounts,
    this.onOpenActivityLog,
    this.onOpenUsers,
    this.onOpenShopSettings,
    this.onPreviewPdf,
    this.onPrintReport,
    this.onExportArchive,
  });

  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenActivityLog;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;
  final ReportActionCallback? onPreviewPdf;
  final ReportActionCallback? onPrintReport;
  final ReportActionCallback? onExportArchive;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  ReportType _selectedType = ReportType.salesSummary;
  ReportPeriodPreset _selectedPreset = ReportPeriodPreset.month;
  ReportGranularity _granularity = ReportGranularity.summary;
  late DateTimeRange _dateRange = _rangeForPreset(_selectedPreset);
  bool _includeAuditTrail = true;
  bool _includePreparedBy = true;
  _ReportOutputAction? _runningAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final selectedType = _effectiveSelectedType();

    return PointyScaffold(
      drawer: AppNavigationDrawer(
        selectedDestination: AppNavigationDestination.reports,
        currentUser: widget.currentUser,
        capabilities: widget.capabilities,
        onOpenDashboard: widget.onOpenDashboard,
        onOpenPos: widget.onOpenPos,
        onOpenPurchasing: widget.onOpenPurchasing,
        onOpenContacts: widget.onOpenContacts,
        onOpenCatalog: widget.onOpenCatalog,
        onOpenCategories: widget.onOpenCategories,
        onOpenRegisterSessions: widget.onOpenRegisterSessions,
        onOpenDeviceSettings: widget.onOpenDeviceSettings,
        onOpenDiscounts: widget.onOpenDiscounts,
        onOpenReports: () {},
        onOpenActivityLog: widget.onOpenActivityLog,
        onOpenUsers: widget.onOpenUsers,
        onOpenShopSettings: widget.onOpenShopSettings,
        onLogout: widget.onLogout,
      ),
      appBar: AppBar(
        leading: const PointyNavigationMenuButton(),
        title: Text(l10n.reportsTitle),
      ),
      body: ReportsGuard(
        capabilities: widget.capabilities,
        child: _ReportsWorkspace(
          capabilities: widget.capabilities,
          selectedType: selectedType,
          selectedPreset: _selectedPreset,
          dateRange: _dateRange,
          granularity: _granularity,
          includeAuditTrail: _includeAuditTrail,
          includePreparedBy: _includePreparedBy,
          runningAction: _runningAction,
          onSelectType: _selectReportType,
          onOpenTypeDetails: _openReportDetails,
          onSelectPreset: (preset) {
            setState(() {
              _selectedPreset = preset;
              if (preset != ReportPeriodPreset.custom) {
                _dateRange = _rangeForPreset(preset);
              }
            });
          },
          onSelectStartDate: () => _pickDate(isStart: true),
          onSelectEndDate: () => _pickDate(isStart: false),
          onSelectGranularity: (granularity) {
            setState(() {
              _granularity = granularity;
            });
          },
          onToggleAuditTrail: (value) {
            setState(() {
              _includeAuditTrail = value;
            });
          },
          onTogglePreparedBy: (value) {
            setState(() {
              _includePreparedBy = value;
            });
          },
          onRunAction: _runAction,
        ),
      ),
    );
  }

  void _selectReportType(ReportType type) {
    setState(() {
      _selectedType = type;
    });
  }

  void _openReportDetails(ReportType type) {
    _selectReportType(type);
    unawaited(_showReportDetailsSheet());
  }

  Future<void> _showReportDetailsSheet() {
    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      maxHeightFactor: 0.92,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void refreshSheet() {
              if (sheetContext.mounted) {
                setSheetState(() {});
              }
            }

            return _CompactReportDetailsSheet(
              child: _ReportConfiguration(
                selectedType: _effectiveSelectedType(),
                selectedPreset: _selectedPreset,
                dateRange: _dateRange,
                granularity: _granularity,
                includeAuditTrail: _includeAuditTrail,
                includePreparedBy: _includePreparedBy,
                runningAction: _runningAction,
                onSelectPreset: (preset) {
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _selectedPreset = preset;
                    if (preset != ReportPeriodPreset.custom) {
                      _dateRange = _rangeForPreset(preset);
                    }
                  });
                  refreshSheet();
                },
                onSelectStartDate: () {
                  unawaited(
                    _pickDate(isStart: true, onStateChanged: refreshSheet),
                  );
                },
                onSelectEndDate: () {
                  unawaited(
                    _pickDate(isStart: false, onStateChanged: refreshSheet),
                  );
                },
                onSelectGranularity: (granularity) {
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _granularity = granularity;
                  });
                  refreshSheet();
                },
                onToggleAuditTrail: (value) {
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _includeAuditTrail = value;
                  });
                  refreshSheet();
                },
                onTogglePreparedBy: (value) {
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _includePreparedBy = value;
                  });
                  refreshSheet();
                },
                onRunAction: (action) {
                  unawaited(_runAction(action, onStateChanged: refreshSheet));
                },
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _pickDate({
    required bool isStart,
    VoidCallback? onStateChanged,
  }) async {
    final initialDate = isStart ? _dateRange.start : _dateRange.end;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (pickedDate == null || !mounted) {
      return;
    }

    setState(() {
      _selectedPreset = ReportPeriodPreset.custom;
      if (isStart) {
        final end = pickedDate.isAfter(_dateRange.end)
            ? pickedDate
            : _dateRange.end;
        _dateRange = DateTimeRange(start: pickedDate, end: end);
        return;
      }

      final start = pickedDate.isBefore(_dateRange.start)
          ? pickedDate
          : _dateRange.start;
      _dateRange = DateTimeRange(start: start, end: pickedDate);
    });
    onStateChanged?.call();
  }

  Future<void> _runAction(
    _ReportOutputAction action, {
    VoidCallback? onStateChanged,
  }) async {
    if (_runningAction != null) {
      return;
    }

    final request = ReportRequest(
      type: _effectiveSelectedType(),
      periodPreset: _selectedPreset,
      dateRange: _dateRange,
      granularity: _granularity,
      includeAuditTrail: _includeAuditTrail,
      includePreparedBy: _includePreparedBy,
    );
    final callback = switch (action) {
      _ReportOutputAction.previewPdf => widget.onPreviewPdf,
      _ReportOutputAction.printReport => widget.onPrintReport,
      _ReportOutputAction.exportArchive => widget.onExportArchive,
    };

    if (callback == null) {
      final l10n = AppLocalizations.of(context)!;
      final actionLabel = _outputActionLabel(l10n, action);
      final reportTitle = _reportTitle(l10n, request.type);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.reportActionPlaceholder(actionLabel, reportTitle)),
        ),
      );
      return;
    }

    setState(() {
      _runningAction = action;
    });
    onStateChanged?.call();
    try {
      await callback(request);
    } catch (_) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        _showActionMessage(
          l10n.reportActionError(_outputActionLabel(l10n, action)),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _runningAction = null;
        });
        onStateChanged?.call();
      }
    }
  }

  DateTimeRange _rangeForPreset(ReportPeriodPreset preset) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (preset) {
      ReportPeriodPreset.today => DateTimeRange(start: today, end: today),
      ReportPeriodPreset.week => DateTimeRange(
        start: today.subtract(Duration(days: today.weekday - 1)),
        end: today,
      ),
      ReportPeriodPreset.month => DateTimeRange(
        start: DateTime(today.year, today.month),
        end: today,
      ),
      ReportPeriodPreset.custom => _dateRange,
    };
  }

  ReportType _effectiveSelectedType() {
    if (_isReportAvailable(_selectedType, widget.capabilities)) {
      return _selectedType;
    }
    final availableReports = _availableReportDefinitions(widget.capabilities);
    return availableReports.isEmpty
        ? _selectedType
        : availableReports.first.type;
  }

  void _showActionMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ReportsWorkspace extends StatelessWidget {
  const _ReportsWorkspace({
    required this.capabilities,
    required this.selectedType,
    required this.selectedPreset,
    required this.dateRange,
    required this.granularity,
    required this.includeAuditTrail,
    required this.includePreparedBy,
    required this.runningAction,
    required this.onSelectType,
    required this.onOpenTypeDetails,
    required this.onSelectPreset,
    required this.onSelectStartDate,
    required this.onSelectEndDate,
    required this.onSelectGranularity,
    required this.onToggleAuditTrail,
    required this.onTogglePreparedBy,
    required this.onRunAction,
  });

  final AuthorizationCapabilities capabilities;
  final ReportType selectedType;
  final ReportPeriodPreset selectedPreset;
  final DateTimeRange dateRange;
  final ReportGranularity granularity;
  final bool includeAuditTrail;
  final bool includePreparedBy;
  final _ReportOutputAction? runningAction;
  final ValueChanged<ReportType> onSelectType;
  final ValueChanged<ReportType> onOpenTypeDetails;
  final ValueChanged<ReportPeriodPreset> onSelectPreset;
  final VoidCallback onSelectStartDate;
  final VoidCallback onSelectEndDate;
  final ValueChanged<ReportGranularity> onSelectGranularity;
  final ValueChanged<bool> onToggleAuditTrail;
  final ValueChanged<bool> onTogglePreparedBy;
  final ValueChanged<_ReportOutputAction> onRunAction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final isCompact = width < 900;

        if (!isCompact) {
          return TwoPaneLayout(
            dualPaneBreakpoint: 900,
            secondaryFirst: true,
            secondaryPaneWidth: 380,
            secondaryPane: _ReportCatalog(
              capabilities: capabilities,
              selectedType: selectedType,
              onSelectType: onSelectType,
            ),
            primaryPane: AdaptiveMaxWidth(
              width: AppContentWidth.detail,
              child: _ReportConfiguration(
                selectedType: selectedType,
                selectedPreset: selectedPreset,
                dateRange: dateRange,
                granularity: granularity,
                includeAuditTrail: includeAuditTrail,
                includePreparedBy: includePreparedBy,
                runningAction: runningAction,
                onSelectPreset: onSelectPreset,
                onSelectStartDate: onSelectStartDate,
                onSelectEndDate: onSelectEndDate,
                onSelectGranularity: onSelectGranularity,
                onToggleAuditTrail: onToggleAuditTrail,
                onTogglePreparedBy: onTogglePreparedBy,
                onRunAction: onRunAction,
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ReportCatalog(
              capabilities: capabilities,
              selectedType: selectedType,
              onSelectType: onOpenTypeDetails,
              isScrollable: false,
            ),
          ],
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

class _ReportCatalog extends StatelessWidget {
  const _ReportCatalog({
    required this.capabilities,
    required this.selectedType,
    required this.onSelectType,
    this.isScrollable = true,
  });

  final AuthorizationCapabilities capabilities;
  final ReportType selectedType;
  final ValueChanged<ReportType> onSelectType;
  final bool isScrollable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final definitions = _availableReportDefinitions(capabilities);
    final tiles = [
      for (final definition in definitions)
        _ReportTile(
          definition: definition,
          isSelected: definition.type == selectedType,
          onTap: () => onSelectType(definition.type),
        ),
    ];

    if (!isScrollable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionTitle(title: l10n.reportsCatalogTitle),
          const SizedBox(height: 12),
          ..._withSpacing(tiles, const SizedBox(height: 8)),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: _SectionTitle(title: l10n.reportsCatalogTitle),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            itemCount: tiles.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) => tiles[index],
          ),
        ),
      ],
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({
    required this.definition,
    required this.isSelected,
    required this.onTap,
  });

  final _ReportDefinition definition;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card.filled(
      margin: EdgeInsets.zero,
      color: isSelected ? colorScheme.primaryContainer : colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(
                definition.icon,
                color: isSelected
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _reportTitle(l10n, definition.type),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _reportSubtitle(l10n, definition.type),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _DenseChip(
                          label: _reportCategory(l10n, definition.type),
                        ),
                        _DenseChip(label: l10n.reportA4Chip),
                      ],
                    ),
                  ],
                ),
              ),
              if (isSelected) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_circle, color: colorScheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportConfiguration extends StatelessWidget {
  const _ReportConfiguration({
    required this.selectedType,
    required this.selectedPreset,
    required this.dateRange,
    required this.granularity,
    required this.includeAuditTrail,
    required this.includePreparedBy,
    required this.runningAction,
    required this.onSelectPreset,
    required this.onSelectStartDate,
    required this.onSelectEndDate,
    required this.onSelectGranularity,
    required this.onToggleAuditTrail,
    required this.onTogglePreparedBy,
    required this.onRunAction,
  });

  final ReportType selectedType;
  final ReportPeriodPreset selectedPreset;
  final DateTimeRange dateRange;
  final ReportGranularity granularity;
  final bool includeAuditTrail;
  final bool includePreparedBy;
  final _ReportOutputAction? runningAction;
  final ValueChanged<ReportPeriodPreset> onSelectPreset;
  final VoidCallback onSelectStartDate;
  final VoidCallback onSelectEndDate;
  final ValueChanged<ReportGranularity> onSelectGranularity;
  final ValueChanged<bool> onToggleAuditTrail;
  final ValueChanged<bool> onTogglePreparedBy;
  final ValueChanged<_ReportOutputAction> onRunAction;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SelectedReportHeader(selectedType: selectedType),
          const SizedBox(height: 20),
          _PeriodPanel(
            selectedPreset: selectedPreset,
            dateRange: dateRange,
            onSelectPreset: onSelectPreset,
            onSelectStartDate: onSelectStartDate,
            onSelectEndDate: onSelectEndDate,
          ),
          const SizedBox(height: 20),
          _GranularityPanel(
            selectedGranularity: granularity,
            onSelectGranularity: onSelectGranularity,
          ),
          const SizedBox(height: 20),
          _ArchiveOptionsPanel(
            includeAuditTrail: includeAuditTrail,
            includePreparedBy: includePreparedBy,
            onToggleAuditTrail: onToggleAuditTrail,
            onTogglePreparedBy: onTogglePreparedBy,
          ),
          const SizedBox(height: 20),
          _OutputActionsPanel(
            selectedType: selectedType,
            dateRange: dateRange,
            granularity: granularity,
            runningAction: runningAction,
            onRunAction: onRunAction,
          ),
        ],
      ),
    );

    return ListView(children: [content]);
  }
}

class _SelectedReportHeader extends StatelessWidget {
  const _SelectedReportHeader({required this.selectedType});

  final ReportType selectedType;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _reportTitle(l10n, selectedType),
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          _reportSubtitle(l10n, selectedType),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _DenseChip(label: _reportCategory(l10n, selectedType)),
            _DenseChip(label: l10n.reportA4Chip),
            _DenseChip(label: l10n.reportAuditableChip),
            _DenseChip(label: l10n.reportArchiveChip),
          ],
        ),
      ],
    );
  }
}

class _PeriodPanel extends StatelessWidget {
  const _PeriodPanel({
    required this.selectedPreset,
    required this.dateRange,
    required this.onSelectPreset,
    required this.onSelectStartDate,
    required this.onSelectEndDate,
  });

  final ReportPeriodPreset selectedPreset;
  final DateTimeRange dateRange;
  final ValueChanged<ReportPeriodPreset> onSelectPreset;
  final VoidCallback onSelectStartDate;
  final VoidCallback onSelectEndDate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _SettingsSection(
      title: l10n.reportPeriodTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<ReportPeriodPreset>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: ReportPeriodPreset.today,
                  label: Text(l10n.reportPeriodToday),
                ),
                ButtonSegment(
                  value: ReportPeriodPreset.week,
                  label: Text(l10n.reportPeriodWeek),
                ),
                ButtonSegment(
                  value: ReportPeriodPreset.month,
                  label: Text(l10n.reportPeriodMonth),
                ),
                ButtonSegment(
                  value: ReportPeriodPreset.custom,
                  label: Text(l10n.reportPeriodCustom),
                ),
              ],
              selected: {selectedPreset},
              onSelectionChanged: (selection) =>
                  onSelectPreset(selection.first),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onSelectStartDate,
                icon: const Icon(Icons.event_outlined),
                label: Text(
                  l10n.reportFromDateValue(formatDate(dateRange.start)),
                ),
              ),
              OutlinedButton.icon(
                onPressed: onSelectEndDate,
                icon: const Icon(Icons.event_available_outlined),
                label: Text(l10n.reportToDateValue(formatDate(dateRange.end))),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GranularityPanel extends StatelessWidget {
  const _GranularityPanel({
    required this.selectedGranularity,
    required this.onSelectGranularity,
  });

  final ReportGranularity selectedGranularity;
  final ValueChanged<ReportGranularity> onSelectGranularity;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _SettingsSection(
      title: l10n.reportGranularityTitle,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<ReportGranularity>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: ReportGranularity.summary,
              label: Text(l10n.reportGranularitySummary),
            ),
            ButtonSegment(
              value: ReportGranularity.daily,
              label: Text(l10n.reportGranularityDaily),
            ),
            ButtonSegment(
              value: ReportGranularity.detailed,
              label: Text(l10n.reportGranularityDetailed),
            ),
          ],
          selected: {selectedGranularity},
          onSelectionChanged: (selection) =>
              onSelectGranularity(selection.first),
        ),
      ),
    );
  }
}

class _ArchiveOptionsPanel extends StatelessWidget {
  const _ArchiveOptionsPanel({
    required this.includeAuditTrail,
    required this.includePreparedBy,
    required this.onToggleAuditTrail,
    required this.onTogglePreparedBy,
  });

  final bool includeAuditTrail;
  final bool includePreparedBy;
  final ValueChanged<bool> onToggleAuditTrail;
  final ValueChanged<bool> onTogglePreparedBy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return _SettingsSection(
      title: l10n.reportArchiveOptionsTitle,
      child: Column(
        children: [
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(l10n.reportIncludeAuditTrailLabel),
            value: includeAuditTrail,
            onChanged: (value) => onToggleAuditTrail(value ?? false),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(l10n.reportIncludePreparedByLabel),
            value: includePreparedBy,
            onChanged: (value) => onTogglePreparedBy(value ?? false),
          ),
        ],
      ),
    );
  }
}

class _OutputActionsPanel extends StatelessWidget {
  const _OutputActionsPanel({
    required this.selectedType,
    required this.dateRange,
    required this.granularity,
    required this.runningAction,
    required this.onRunAction,
  });

  final ReportType selectedType;
  final DateTimeRange dateRange;
  final ReportGranularity granularity;
  final _ReportOutputAction? runningAction;
  final ValueChanged<_ReportOutputAction> onRunAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final range = l10n.reportDateRangeValue(
      formatDate(dateRange.start),
      formatDate(dateRange.end),
    );
    final granularityLabel = _granularityLabel(l10n, granularity);
    final runningLabel = runningAction == null
        ? null
        : _outputActionLabel(l10n, runningAction!);

    return _SettingsSection(
      title: l10n.reportOutputTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointyFilterSummaryBar(
            items: [
              PointyFilterSummaryItem(
                label: l10n.reportSelectedSummary(range, granularityLabel),
                icon: Icons.filter_alt_outlined,
                selected: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (runningLabel != null) ...[
            _ReportActionProgress(
              label: l10n.reportActionInProgress(runningLabel),
            ),
            const SizedBox(height: 12),
          ],
          ResponsiveActionBar(
            actions: [
              FilledButton.icon(
                onPressed: runningAction != null
                    ? null
                    : () => onRunAction(_ReportOutputAction.previewPdf),
                icon: _ReportActionIcon(
                  icon: Icons.picture_as_pdf_outlined,
                  isRunning: runningAction == _ReportOutputAction.previewPdf,
                ),
                label: Text(l10n.reportPreviewPdfAction),
              ),
              FilledButton.tonalIcon(
                onPressed: runningAction != null
                    ? null
                    : () => onRunAction(_ReportOutputAction.printReport),
                icon: _ReportActionIcon(
                  icon: Icons.print_outlined,
                  isRunning: runningAction == _ReportOutputAction.printReport,
                ),
                label: Text(l10n.reportPrintAction),
              ),
              OutlinedButton.icon(
                onPressed: runningAction != null
                    ? null
                    : () => onRunAction(_ReportOutputAction.exportArchive),
                icon: _ReportActionIcon(
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

class _ReportActionProgress extends StatelessWidget {
  const _ReportActionProgress({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _ReportActionIcon extends StatelessWidget {
  const _ReportActionIcon({required this.icon, required this.isRunning});

  final IconData icon;
  final bool isRunning;

  @override
  Widget build(BuildContext context) {
    if (!isRunning) {
      return Icon(icon);
    }
    return const SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(strokeWidth: 2.5),
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

class _ReportDefinition {
  const _ReportDefinition({required this.type, required this.icon});

  final ReportType type;
  final IconData icon;
}

enum _ReportOutputAction { previewPdf, printReport, exportArchive }

const _reportDefinitions = [
  _ReportDefinition(
    type: ReportType.salesSummary,
    icon: Icons.trending_up_outlined,
  ),
  _ReportDefinition(
    type: ReportType.registerSessions,
    icon: Icons.manage_history_outlined,
  ),
  _ReportDefinition(type: ReportType.payments, icon: Icons.payments_outlined),
  _ReportDefinition(
    type: ReportType.inventoryValue,
    icon: Icons.inventory_2_outlined,
  ),
  _ReportDefinition(type: ReportType.stockMovement, icon: Icons.swap_vert),
  _ReportDefinition(
    type: ReportType.purchases,
    icon: Icons.add_shopping_cart_outlined,
  ),
];

List<_ReportDefinition> _availableReportDefinitions(
  AuthorizationCapabilities capabilities,
) {
  return [
    for (final definition in _reportDefinitions)
      if (_isReportAvailable(definition.type, capabilities)) definition,
  ];
}

bool _isReportAvailable(
  ReportType type,
  AuthorizationCapabilities capabilities,
) {
  return switch (type) {
    ReportType.salesSummary => capabilities.canViewSalesDashboard,
    ReportType.registerSessions => capabilities.canViewRegisterSessions,
    ReportType.payments => capabilities.canViewPaymentDashboard,
    ReportType.inventoryValue ||
    ReportType.stockMovement => capabilities.canViewStock,
    ReportType.purchases => capabilities.canAccessPurchasing,
  };
}

List<Widget> _withSpacing(List<Widget> children, Widget spacer) {
  if (children.isEmpty) {
    return const [];
  }

  return [
    for (var index = 0; index < children.length; index++) ...[
      if (index > 0) spacer,
      children[index],
    ],
  ];
}

String _reportTitle(AppLocalizations l10n, ReportType type) {
  return switch (type) {
    ReportType.salesSummary => l10n.reportSalesSummaryTitle,
    ReportType.registerSessions => l10n.reportRegisterSessionsTitle,
    ReportType.payments => l10n.reportPaymentsTitle,
    ReportType.inventoryValue => l10n.reportInventoryValueTitle,
    ReportType.stockMovement => l10n.reportStockMovementTitle,
    ReportType.purchases => l10n.reportPurchasesTitle,
  };
}

String _reportSubtitle(AppLocalizations l10n, ReportType type) {
  return switch (type) {
    ReportType.salesSummary => l10n.reportSalesSummarySubtitle,
    ReportType.registerSessions => l10n.reportRegisterSessionsSubtitle,
    ReportType.payments => l10n.reportPaymentsSubtitle,
    ReportType.inventoryValue => l10n.reportInventoryValueSubtitle,
    ReportType.stockMovement => l10n.reportStockMovementSubtitle,
    ReportType.purchases => l10n.reportPurchasesSubtitle,
  };
}

String _reportCategory(AppLocalizations l10n, ReportType type) {
  return switch (type) {
    ReportType.salesSummary => l10n.reportCategorySales,
    ReportType.registerSessions => l10n.reportCategoryCash,
    ReportType.payments => l10n.reportCategoryPayments,
    ReportType.inventoryValue ||
    ReportType.stockMovement => l10n.reportCategoryInventory,
    ReportType.purchases => l10n.reportCategoryPurchasing,
  };
}

String _granularityLabel(AppLocalizations l10n, ReportGranularity granularity) {
  return switch (granularity) {
    ReportGranularity.summary => l10n.reportGranularitySummary,
    ReportGranularity.daily => l10n.reportGranularityDaily,
    ReportGranularity.detailed => l10n.reportGranularityDetailed,
  };
}

String _outputActionLabel(AppLocalizations l10n, _ReportOutputAction action) {
  return switch (action) {
    _ReportOutputAction.previewPdf => l10n.reportPreviewPdfAction,
    _ReportOutputAction.printReport => l10n.reportPrintAction,
    _ReportOutputAction.exportArchive => l10n.reportExportArchiveAction,
  };
}
