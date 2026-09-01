import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/attendance.dart';
import '../../../data/models/employee.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/attendance_view_model.dart';

String attendanceStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    'present' => l10n.attendanceStatusPresent,
    'late' => l10n.attendanceStatusLate,
    'partial' => l10n.attendanceStatusPartial,
    'day_off' => l10n.attendanceStatusDayOff,
    _ => status,
  };
}

/// Month-by-employee attendance review inside the employees workspace.
class AttendanceReviewTab extends StatefulWidget {
  const AttendanceReviewTab({
    super.key,
    required this.viewModel,
    required this.employees,
  });

  final AttendanceViewModel viewModel;
  final List<Employee> employees;

  @override
  State<AttendanceReviewTab> createState() => _AttendanceReviewTabState();
}

class _AttendanceReviewTabState extends State<AttendanceReviewTab> {
  int? _employeeId;
  late DateTime _month;
  var _seededMonth = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    widget.viewModel.addListener(_seedMonthFromCoverage);
    // The payroll workspace never loads the connection config, so without this
    // the coverage window is unknown here and the month below cannot be seeded
    // from it. Cheap and best-effort: it only fetches the connection row, and
    // a role that cannot read it simply leaves the config null.
    unawaited(widget.viewModel.ensureConfigLoaded());
    _seedMonthFromCoverage();
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_seedMonthFromCoverage);
    super.dispose();
  }

  /// Open on the last month that actually has data, not on today.
  ///
  /// A shop whose BioTime history stops months ago (an old server, a terminal
  /// that stopped uploading) would otherwise land on an empty current month
  /// with nothing to say why, and the only way back to the data is clicking the
  /// arrow once per month.
  void _seedMonthFromCoverage() {
    if (_seededMonth) {
      return;
    }
    final through = widget.viewModel.config?.syncedThrough;
    if (through == null) {
      return;
    }
    _seededMonth = true;
    final latest = DateTime(through.year, through.month);
    if (latest.isBefore(_month)) {
      setState(() => _month = latest);
      _load();
    }
  }

  /// The month lies entirely outside the window we hold data for, so an empty
  /// list means "not imported", not "nobody came in".
  bool get _isOutsideImportedData {
    final config = widget.viewModel.config;
    final from = config?.syncedFrom;
    final through = config?.syncedThrough;
    if (from == null || through == null) {
      return false;
    }
    return _monthEnd.isBefore(DateTime(from.year, from.month, from.day)) ||
        _monthStart.isAfter(DateTime(through.year, through.month, through.day));
  }

  void _jumpToLatestData() {
    final through = widget.viewModel.config?.syncedThrough;
    if (through == null) {
      return;
    }
    setState(() => _month = DateTime(through.year, through.month));
    _load();
  }

  DateTime get _monthStart => _month;
  DateTime get _monthEnd => DateTime(_month.year, _month.month + 1, 0);

  void _load() {
    final employeeId = _employeeId;
    if (employeeId == null) {
      return;
    }
    unawaited(
      widget.viewModel.loadReview(
        employeeId: employeeId,
        dateFrom: _monthStart,
        dateTo: _monthEnd,
      ),
    );
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final spacing = AdaptiveSpacing.of(context);
        final viewModel = widget.viewModel;

        return ListView(
          children: [
            _controls(context, l10n),
            SizedBox(height: spacing.sm),
            if (_employeeId == null)
              PointyEmptyState(
                title: l10n.attendanceSelectEmployeeHint,
                icon: Icons.fingerprint,
              )
            else if (viewModel.isLoading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: PointySpinner()),
              )
            else if (viewModel.hasLoadError)
              PointyErrorState(
                title: l10n.attendanceLoadError,
                icon: Icons.fingerprint,
                action: FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.sync),
                  label: Text(l10n.retryButton),
                ),
              )
            else ...[
              if (viewModel.summary != null) ...[
                _summaryCards(context, l10n, viewModel.summary!),
                SizedBox(height: spacing.sm),
              ],
              if (viewModel.days.isEmpty)
                if (_isOutsideImportedData)
                  PointyEmptyState(
                    title: l10n.attendanceMonthOutsideDataMessage(
                      formatDate(viewModel.config!.syncedFrom!),
                      formatDate(viewModel.config!.syncedThrough!),
                    ),
                    icon: Icons.cloud_off_outlined,
                    action: FilledButton.tonalIcon(
                      onPressed: _jumpToLatestData,
                      icon: const Icon(Icons.history),
                      label: Text(l10n.attendanceJumpToLatestDataButton),
                    ),
                  )
                else
                  PointyEmptyState(
                    title: l10n.attendanceNoDaysMessage,
                    icon: Icons.event_busy_outlined,
                  )
              else
                for (final day in viewModel.days) _DayTile(day: day),
            ],
          ],
        );
      },
    );
  }

  Widget _controls(BuildContext context, AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<int>(
          initialValue: _employeeId,
          decoration: InputDecoration(
            labelText: l10n.attendanceSelectEmployeeLabel,
            prefixIcon: const Icon(Icons.person_search_outlined),
          ),
          items: [
            for (final employee in widget.employees)
              DropdownMenuItem(
                value: employee.id,
                child: Text(employee.fullName, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (value) {
            setState(() => _employeeId = value);
            _load();
          },
        ),
        SizedBox(height: spacing.sm),
        Row(
          children: [
            IconButton(
              tooltip: l10n.attendanceMonthLabel,
              onPressed: () => _shiftMonth(-1),
              icon: const Icon(Icons.arrow_back),
            ),
            Expanded(
              child: Center(
                child: Text(
                  formatMonthYear(_month),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.attendanceMonthLabel,
              onPressed: () => _shiftMonth(1),
              icon: const Icon(Icons.arrow_forward),
            ),
          ],
        ),
      ],
    );
  }

  Widget _summaryCards(
    BuildContext context,
    AppLocalizations l10n,
    AttendanceSummary summary,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _SummaryChip(
          label: l10n.attendanceSummaryExpectedLabel,
          value: '${summary.expectedDays}',
          icon: Icons.calendar_month_outlined,
        ),
        _SummaryChip(
          label: l10n.attendanceSummaryPresentLabel,
          value: '${summary.presentDays}',
          icon: Icons.check_circle_outline,
        ),
        _SummaryChip(
          label: l10n.attendanceSummaryAbsentLabel,
          value: '${summary.absentDays}',
          icon: Icons.cancel_outlined,
          isWarning: summary.absentDays > 0,
        ),
        _SummaryChip(
          label: l10n.attendanceSummaryLateLabel,
          value: '${summary.lateMinutes}',
          icon: Icons.schedule_outlined,
          isWarning: summary.lateMinutes > 0,
        ),
        _SummaryChip(
          label: l10n.attendanceSummaryOvertimeLabel,
          value: '${summary.overtimeMinutes}',
          icon: Icons.more_time_outlined,
        ),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.label,
    required this.value,
    required this.icon,
    this.isWarning = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Chip(
      avatar: Icon(
        icon,
        size: 18,
        color: isWarning ? colors.danger : colors.primaryStrong,
      ),
      label: Text('$label: $value'),
    );
  }
}

class _DayTile extends StatelessWidget {
  const _DayTile({required this.day});

  final AttendanceDayEntry day;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final isProblem = day.status == 'late' || day.status == 'partial';
    final worked = day.workedMinutes >= 60
        ? '${(day.workedMinutes / 60).toStringAsFixed(1)}h'
        : '${day.workedMinutes}m';

    return PointyDataRow(
      leading: Icon(switch (day.status) {
        'present' => Icons.check_circle_outline,
        'late' => Icons.schedule_outlined,
        'partial' => Icons.error_outline,
        'day_off' => Icons.weekend_outlined,
        _ => Icons.help_outline,
      }, color: isProblem ? colors.danger : colors.primaryStrong),
      title:
          '${formatDate(day.date)} — ${attendanceStatusLabel(l10n, day.status)}',
      subtitle: [
        if (day.firstIn != null)
          l10n.attendanceDayTimes(
            formatClockTime(day.firstIn!),
            day.lastOut == null ? '—' : formatClockTime(day.lastOut!),
          ),
        l10n.attendanceDayMetrics(worked, day.lateMinutes, day.overtimeMinutes),
      ].join(' • '),
    );
  }
}
