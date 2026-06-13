import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/attendance.dart';
import '../../../data/models/employee.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
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

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
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
                child: Center(child: CircularProgressIndicator()),
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
                PointyEmptyState(
                  title: l10n.attendanceNoDaysMessage,
                  icon: Icons.event_busy_outlined,
                )
              else
                for (final day in viewModel.days)
                  _DayTile(day: day),
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
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final employee in widget.employees)
              DropdownMenuItem(
                value: employee.id,
                child: Text(
                  employee.fullName,
                  overflow: TextOverflow.ellipsis,
                ),
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
    final colorScheme = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(
        icon,
        size: 18,
        color: isWarning ? colorScheme.error : colorScheme.primary,
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
    final colorScheme = Theme.of(context).colorScheme;
    final isProblem = day.status == 'late' || day.status == 'partial';
    final worked = day.workedMinutes >= 60
        ? '${(day.workedMinutes / 60).toStringAsFixed(1)}h'
        : '${day.workedMinutes}m';

    return PointyDataRow(
      leading: Icon(
        switch (day.status) {
          'present' => Icons.check_circle_outline,
          'late' => Icons.schedule_outlined,
          'partial' => Icons.error_outline,
          'day_off' => Icons.weekend_outlined,
          _ => Icons.help_outline,
        },
        color: isProblem ? colorScheme.error : colorScheme.primary,
      ),
      title:
          '${formatDate(day.date)} — ${attendanceStatusLabel(l10n, day.status)}',
      subtitle: [
        if (day.firstIn != null)
          l10n.attendanceDayTimes(
            formatTime(day.firstIn!.toLocal()),
            day.lastOut == null ? '—' : formatTime(day.lastOut!.toLocal()),
          ),
        l10n.attendanceDayMetrics(worked, day.lateMinutes, day.overtimeMinutes),
      ].join(' • '),
    );
  }
}
