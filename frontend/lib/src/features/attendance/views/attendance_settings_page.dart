import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/attendance.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/attendance_view_model.dart';

/// Weekday labels keyed by python weekday number (Monday = 0 .. Sunday = 6).
String weekdayLabel(AppLocalizations l10n, int weekday) {
  return switch (weekday) {
    0 => l10n.weekdayMonday,
    1 => l10n.weekdayTuesday,
    2 => l10n.weekdayWednesday,
    3 => l10n.weekdayThursday,
    4 => l10n.weekdayFriday,
    5 => l10n.weekdaySaturday,
    _ => l10n.weekdaySunday,
  };
}

class AttendanceSettingsPage extends StatefulWidget {
  const AttendanceSettingsPage({super.key, required this.viewModel});

  final AttendanceViewModel viewModel;

  @override
  State<AttendanceSettingsPage> createState() => _AttendanceSettingsPageState();
}

class _AttendanceSettingsPageState extends State<AttendanceSettingsPage> {
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _graceController = TextEditingController();
  var _seededFromConfig = false;
  var _isEnabled = false;
  var _workdays = <int>{};
  TimeOfDay _shiftStart = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _shiftEnd = const TimeOfDay(hour: 17, minute: 0);

  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_seedFromConfig);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.loadSettings());
      }
    });
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_seedFromConfig);
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _graceController.dispose();
    super.dispose();
  }

  void _seedFromConfig() {
    final config = widget.viewModel.config;
    if (config == null || _seededFromConfig) {
      return;
    }
    setState(() {
      _seededFromConfig = true;
      _urlController.text = config.baseUrl;
      _usernameController.text = config.username;
      _graceController.text = '${config.graceMinutes}';
      _isEnabled = config.isEnabled;
      _workdays = config.workdays.toSet();
      _shiftStart = _parseTime(config.shiftStart) ?? _shiftStart;
      _shiftEnd = _parseTime(config.shiftEnd) ?? _shiftEnd;
    });
  }

  TimeOfDay? _parseTime(String value) {
    final parts = value.split(':');
    if (parts.length < 2) {
      return null;
    }
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) {
      return null;
    }
    return TimeOfDay(hour: hour, minute: minute);
  }

  String _timeParam(TimeOfDay value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
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
            title: Text(l10n.attendanceSettingsSectionTitle),
            isLoading:
                viewModel.isLoading ||
                viewModel.isMutating ||
                viewModel.isSyncing,
            actions: [
              IconButton(
                tooltip: l10n.attendanceSyncNowButton,
                onPressed:
                    viewModel.isSyncing || !viewModel.isEnabled
                    ? null
                    : () => _syncNow(context),
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: _buildBody(context, l10n),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.config == null) {
      return const PointyLoadingArea();
    }
    if (viewModel.hasLoadError && viewModel.config == null) {
      return PointyErrorState(
        title: l10n.attendanceSettingsLoadError,
        icon: Icons.fingerprint,
        action: FilledButton.icon(
          onPressed: viewModel.loadSettings,
          icon: const Icon(Icons.sync),
          label: Text(l10n.retryButton),
        ),
      );
    }

    return SingleChildScrollView(
      padding: spacing.pagePadding,
      child: AdaptiveMaxWidth(
        width: AppContentWidth.form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _connectionCard(context, l10n),
            SizedBox(height: spacing.md),
            _scheduleCard(context, l10n),
            SizedBox(height: spacing.md),
            _syncStatusCard(context, l10n),
            SizedBox(height: spacing.md),
            _mappingCard(context, l10n),
          ],
        ),
      ),
    );
  }

  Widget _connectionCard(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.attendanceConnectionSectionTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: spacing.xs),
          Text(
            l10n.attendanceConnectionSectionSubtitle,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: l10n.attendanceServerUrlLabel,
              hintText: l10n.attendanceServerUrlHint,
              prefixIcon: const Icon(Icons.dns_outlined),
            ),
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _usernameController,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: l10n.attendanceUsernameLabel,
              prefixIcon: const Icon(Icons.person_outline),
            ),
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _passwordController,
            obscureText: true,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: l10n.attendancePasswordLabel,
              helperText: widget.viewModel.config?.hasPassword == true
                  ? l10n.attendancePasswordKeepHint
                  : null,
              prefixIcon: const Icon(Icons.key_outlined),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.attendanceEnableLabel),
            subtitle: Text(l10n.attendanceEnableSubtitle),
            value: _isEnabled,
            onChanged: viewModel.isMutating
                ? null
                : (value) => setState(() => _isEnabled = value),
          ),
          SizedBox(height: spacing.sm),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: viewModel.isMutating
                      ? null
                      : () => _save(context),
                  icon: const Icon(Icons.save_outlined),
                  label: Text(l10n.saveSettingsButton),
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: viewModel.isMutating
                      ? null
                      : () => _testConnection(context),
                  icon: const Icon(Icons.network_check_outlined),
                  label: Text(l10n.attendanceTestConnectionButton),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _scheduleCard(BuildContext context, AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.attendanceScheduleSectionTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: spacing.xs),
          Text(
            l10n.attendanceScheduleSectionSubtitle,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          SizedBox(height: spacing.sm),
          Row(
            children: [
              Expanded(
                child: _timeField(
                  context,
                  label: l10n.attendanceShiftStartLabel,
                  value: _shiftStart,
                  onPicked: (picked) => setState(() => _shiftStart = picked),
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: _timeField(
                  context,
                  label: l10n.attendanceShiftEndLabel,
                  value: _shiftEnd,
                  onPicked: (picked) => setState(() => _shiftEnd = picked),
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _graceController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l10n.attendanceGraceLabel,
              prefixIcon: const Icon(Icons.timer_outlined),
            ),
          ),
          SizedBox(height: spacing.sm),
          Text(
            l10n.attendanceWorkdaysLabel,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          SizedBox(height: spacing.xs),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final weekday in const [5, 6, 0, 1, 2, 3, 4])
                FilterChip(
                  label: Text(weekdayLabel(l10n, weekday)),
                  selected: _workdays.contains(weekday),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _workdays.add(weekday);
                      } else {
                        _workdays.remove(weekday);
                      }
                    });
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _timeField(
    BuildContext context, {
    required String label,
    required TimeOfDay value,
    required ValueChanged<TimeOfDay> onPicked,
  }) {
    return OutlinedButton.icon(
      onPressed: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: value,
        );
        if (picked != null) {
          onPicked(picked);
        }
      },
      icon: const Icon(Icons.schedule_outlined),
      label: Text('$label: ${_timeParam(value)}'),
    );
  }

  Widget _syncStatusCard(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final config = viewModel.config;
    final spacing = AdaptiveSpacing.of(context);
    final lastSynced = config?.lastSyncedAt;

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointyDataRow(
            leading: const Icon(Icons.sync_outlined),
            title: lastSynced == null
                ? l10n.attendanceNeverSynced
                : l10n.attendanceLastSyncLabel(
                    formatDateTime(lastSynced.toLocal()),
                  ),
            subtitle:
                config != null &&
                    config.lastSyncStatus == 'error' &&
                    config.lastSyncError.isNotEmpty
                ? l10n.attendanceLastSyncErrorLabel(config.lastSyncError)
                : null,
          ),
          SizedBox(height: spacing.sm),
          FilledButton.tonalIcon(
            onPressed: viewModel.isSyncing || !viewModel.isEnabled
                ? null
                : () => _syncNow(context),
            icon: viewModel.isSyncing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: Text(
              viewModel.isSyncing
                  ? l10n.attendanceSyncInProgressButton
                  : l10n.attendanceSyncNowButton,
            ),
          ),
          if (!viewModel.isEnabled) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage(message: l10n.attendanceDisabledNotice),
          ],
        ],
      ),
    );
  }

  Widget _mappingCard(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);
    final unmatched = viewModel.lastSyncResult?.unmatchedBioTime ?? const [];

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.attendanceMappingSectionTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          SizedBox(height: spacing.xs),
          Text(
            l10n.attendanceMappingSectionSubtitle,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          SizedBox(height: spacing.sm),
          if (viewModel.profiles.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: spacing.sm),
              child: Text(l10n.attendanceMappingEmptyState),
            )
          else
            for (final profile in viewModel.profiles)
              _MappingTile(
                profile: profile,
                isMutating: viewModel.isMutating,
                onEditCode: () => _editMappingCode(context, profile),
                onTrackedChanged: (tracked) {
                  unawaited(
                    viewModel.updateProfile(profile, isTracked: tracked),
                  );
                },
              ),
          if (unmatched.isNotEmpty) ...[
            SizedBox(height: spacing.sm),
            Text(
              l10n.attendanceUnmatchedTitle(unmatched.length),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SizedBox(height: spacing.xs),
            for (final person in unmatched)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_off_outlined),
                title: Text(person.name.isEmpty ? person.empCode : person.name),
                subtitle: Text(person.empCode),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final saved = await widget.viewModel.saveConfig(
      AttendanceConfigDraft(
        baseUrl: _urlController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        isEnabled: _isEnabled,
        workdays: _workdays.toList()..sort(),
        shiftStart: _timeParam(_shiftStart),
        shiftEnd: _timeParam(_shiftEnd),
        graceMinutes: int.tryParse(_graceController.text.trim()) ?? 15,
      ),
    );
    if (!mounted) {
      return;
    }
    _passwordController.clear();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved ? l10n.attendanceSettingsSaved : l10n.attendanceSettingsSaveError,
        ),
      ),
    );
  }

  Future<void> _testConnection(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final count = await widget.viewModel.testConnection();
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          count == null
              ? l10n.attendanceTestFailed
              : l10n.attendanceTestSuccess(count),
        ),
      ),
    );
  }

  Future<void> _syncNow(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.viewModel.sync();
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result == null
              ? l10n.attendanceSyncFailed
              : l10n.attendanceSyncSuccess(
                  result.punchesImported,
                  result.matchedEmployees,
                ),
        ),
      ),
    );
  }

  Future<void> _editMappingCode(
    BuildContext context,
    AttendanceProfileLink profile,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: profile.bioTimeEmpCode);
    final newCode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(profile.employeeName),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(
            labelText: l10n.attendanceMappingCodeLabel,
            prefixIcon: const Icon(Icons.fingerprint),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(l10n.confirmButton),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newCode == null) {
      return;
    }
    await widget.viewModel.updateProfile(
      profile,
      bioTimeEmpCode: newCode.trim(),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(padding: EdgeInsets.all(spacing.md), child: child),
    );
  }
}

class _MappingTile extends StatelessWidget {
  const _MappingTile({
    required this.profile,
    required this.isMutating,
    required this.onEditCode,
    required this.onTrackedChanged,
  });

  final AttendanceProfileLink profile;
  final bool isMutating;
  final VoidCallback onEditCode;
  final ValueChanged<bool> onTrackedChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.badge_outlined),
      title: Text(profile.employeeName),
      subtitle: Text(
        [
          profile.employeeNumber,
          if (profile.bioTimeEmpCode.isNotEmpty)
            '${l10n.attendanceMappingCodeLabel}: ${profile.bioTimeEmpCode}',
          if (profile.bioTimeFullName.isNotEmpty) profile.bioTimeFullName,
        ].join(' • '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n.attendanceMappingCodeLabel,
            onPressed: isMutating ? null : onEditCode,
            icon: const Icon(Icons.edit_outlined),
          ),
          Switch(
            value: profile.isTracked,
            onChanged: isMutating ? null : onTrackedChanged,
          ),
        ],
      ),
    );
  }
}
