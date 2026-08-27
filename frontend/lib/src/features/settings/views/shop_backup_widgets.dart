part of 'shop_settings_screen.dart';

class _BackupOperationsPage extends StatefulWidget {
  const _BackupOperationsPage({required this.viewModel});

  final ShopSettingsViewModel viewModel;

  @override
  State<_BackupOperationsPage> createState() => _BackupOperationsPageState();
}

class _BackupOperationsPageState extends State<_BackupOperationsPage> {
  bool _scheduleInitialized = false;
  bool _scheduleDirty = false;
  bool _showScheduleErrors = false;
  bool _requireDestinationForManualBackup = false;
  bool _backupEnabled = false;
  String _destinationPath = '';
  TimeOfDay _scheduledTime = const TimeOfDay(hour: 2, minute: 0);
  int _retentionCount = 7;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.viewModel.loadBackupOperations());
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final spacing = AdaptiveSpacing.of(context);
        final status = widget.viewModel.backupStatus;
        _syncSchedule(status);
        final activeJob = status?.activeJob;
        final hasActiveJob = activeJob?.isActive ?? false;
        final isBusy =
            widget.viewModel.isSavingBackupSchedule ||
            widget.viewModel.isStartingBackup ||
            widget.viewModel.isRestoringBackup ||
            hasActiveJob;

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.backupRestoreTitle),
            isLoading:
                widget.viewModel.isLoadingBackupOperations ||
                widget.viewModel.isSavingBackupSchedule ||
                widget.viewModel.isStartingBackup ||
                widget.viewModel.isRestoringBackup,
            actions: [
              IconButton(
                tooltip: l10n.backupRefreshTooltip,
                onPressed: widget.viewModel.isLoadingBackupOperations
                    ? null
                    : widget.viewModel.loadBackupOperations,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: status == null && widget.viewModel.isLoadingBackupOperations
              ? const PointyLoadingArea()
              : ListView(
                  padding: spacing.pagePadding,
                  children: [
                    AdaptiveMaxWidth(
                      width: AppContentWidth.form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          PointyDetailSection(
                            icon: Icons.backup_outlined,
                            title: l10n.backupScheduleSectionTitle,
                            child: _BackupScheduleFields(
                              enabled: _backupEnabled,
                              destinationPath: _destinationPath,
                              scheduledTimeText: _formatTimeOfDay(
                                _scheduledTime,
                              ),
                              retentionCount: _retentionCount,
                              destinations: widget.viewModel.backupDestinations,
                              isBusy: isBusy,
                              destinationErrorText: _backupDestinationError(
                                l10n,
                              ),
                              onEnabledChanged: (value) {
                                setState(() {
                                  _backupEnabled = value;
                                  _scheduleDirty = true;
                                });
                              },
                              onDestinationChanged: (value) {
                                setState(() {
                                  _destinationPath = value ?? '';
                                  _scheduleDirty = true;
                                });
                              },
                              onPickTime: isBusy
                                  ? null
                                  : () => _pickBackupTime(context),
                            ),
                          ),
                          SizedBox(height: spacing.md),
                          if (activeJob != null && activeJob.isActive) ...[
                            _BackupJobProgressCard(job: activeJob),
                            SizedBox(height: spacing.md),
                          ],
                          _BackupActionBar(
                            canStartBackup: !isBusy,
                            canSaveSchedule: !isBusy,
                            isSavingSchedule:
                                widget.viewModel.isSavingBackupSchedule,
                            isStartingBackup: widget.viewModel.isStartingBackup,
                            onSaveSchedule: _saveSchedule,
                            onStartBackup: _startBackup,
                          ),
                          if (widget.viewModel.hasBackupOperationsError) ...[
                            SizedBox(height: spacing.md),
                            PointyErrorState(
                              title: l10n.backupOperationFailedMessage,
                              icon: Icons.error_outline,
                            ),
                          ],
                          SizedBox(height: spacing.lg),
                          PointyDetailSection(
                            icon: Icons.restore_outlined,
                            title: l10n.restoreSectionTitle,
                            child: _RestoreBackupFields(
                              isBusy: isBusy,
                              isRestoring: widget.viewModel.isRestoringBackup,
                              onPickRestoreFile: () =>
                                  _pickRestoreArchive(context),
                            ),
                          ),
                          SizedBox(height: spacing.lg),
                          PointyDetailSection(
                            icon: Icons.history_outlined,
                            title: l10n.backupHistorySectionTitle,
                            child: _BackupJobHistory(
                              latestBackup: status?.latestBackupJob,
                              latestRestore: status?.latestRestoreJob,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  void _syncSchedule(BackupOperationsStatus? status) {
    if (_scheduleDirty || status == null) {
      return;
    }
    final schedule = status.schedule;
    if (!_scheduleInitialized ||
        _backupEnabled != schedule.enabled ||
        _destinationPath != schedule.destinationPath ||
        _retentionCount != schedule.retentionCount) {
      _backupEnabled = schedule.enabled;
      _destinationPath = schedule.destinationPath;
      _scheduledTime = _timeOfDayFromApiValue(schedule.scheduledTime);
      _retentionCount = schedule.retentionCount;
      _scheduleInitialized = true;
    }
  }

  String? _backupDestinationError(AppLocalizations l10n) {
    if (!_showScheduleErrors ||
        (!_backupEnabled && !_requireDestinationForManualBackup) ||
        _destinationPath.isNotEmpty) {
      return null;
    }
    return l10n.backupDestinationRequiredError;
  }

  Future<void> _pickBackupTime(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _scheduledTime,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _scheduledTime = picked;
      _scheduleDirty = true;
    });
  }

  Future<void> _saveSchedule() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _showScheduleErrors = true;
      _requireDestinationForManualBackup = false;
    });
    if (_backupDestinationError(l10n) != null) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final saved = await widget.viewModel.updateBackupSchedule(
      BackupScheduleDraft(
        enabled: _backupEnabled,
        destinationPath: _destinationPath,
        scheduledTime: _timeOfDayToApiValue(_scheduledTime),
        retentionCount: _retentionCount,
      ),
    );
    if (!context.mounted) {
      return;
    }
    if (saved) {
      setState(() {
        _scheduleDirty = false;
        _showScheduleErrors = false;
        _requireDestinationForManualBackup = false;
      });
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            saved
                ? l10n.backupScheduleSavedMessage
                : l10n.backupOperationFailedMessage,
          ),
        ),
      );
  }

  Future<void> _startBackup() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _showScheduleErrors = true;
      _requireDestinationForManualBackup = true;
    });
    if (_backupDestinationError(l10n) != null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.backupDestinationRequiredError)),
        );
      return;
    }

    if (_scheduleDirty) {
      final saved = await widget.viewModel.updateBackupSchedule(
        BackupScheduleDraft(
          enabled: _backupEnabled,
          destinationPath: _destinationPath,
          scheduledTime: _timeOfDayToApiValue(_scheduledTime),
          retentionCount: _retentionCount,
        ),
      );
      if (!context.mounted) {
        return;
      }
      if (!saved) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text(l10n.backupOperationFailedMessage)),
          );
        return;
      }
      setState(() {
        _scheduleDirty = false;
        _showScheduleErrors = false;
        _requireDestinationForManualBackup = false;
      });
    }

    final started = await widget.viewModel.startBackup();
    if (!context.mounted) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            started
                ? l10n.backupStartedMessage
                : l10n.backupOperationFailedMessage,
          ),
        ),
      );
  }

  Future<void> _pickRestoreArchive(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      withData: true,
      allowMultiple: false,
    );
    if (!context.mounted) {
      return;
    }
    if (result == null || result.files.isEmpty) {
      return;
    }
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.restorePickErrorMessage)));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AdaptiveDialogSurface(
        size: AdaptiveModalSize.compact,
        child: AlertDialog(
          icon: const Icon(Icons.restore_outlined),
          title: Text(l10n.restoreConfirmTitle),
          content: Text(l10n.restoreConfirmMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.restore_outlined),
              label: Text(l10n.restoreConfirmButton),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) {
      return;
    }

    final started = await widget.viewModel.restoreBackup(
      RestoreBackupUpload(
        filename: file.name,
        bytes: bytes,
        contentType: 'application/zip',
      ),
    );
    if (!mounted) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            started
                ? l10n.restoreStartedMessage
                : l10n.backupOperationFailedMessage,
          ),
        ),
      );
  }
}

class _BackupScheduleFields extends StatelessWidget {
  const _BackupScheduleFields({
    required this.enabled,
    required this.destinationPath,
    required this.scheduledTimeText,
    required this.retentionCount,
    required this.destinations,
    required this.isBusy,
    required this.destinationErrorText,
    required this.onEnabledChanged,
    required this.onDestinationChanged,
    required this.onPickTime,
  });

  final bool enabled;
  final String destinationPath;
  final String scheduledTimeText;
  final int retentionCount;
  final List<BackupDestination> destinations;
  final bool isBusy;
  final String? destinationErrorText;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<String?> onDestinationChanged;
  final VoidCallback? onPickTime;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final usableDestinations = destinations
        .where((destination) => destination.canUse)
        .toList(growable: false);
    BackupDestination? selectedDestination;
    for (final destination in destinations) {
      if (destination.path == destinationPath) {
        selectedDestination = destination;
        break;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: enabled,
          title: Text(l10n.backupScheduleEnabledLabel),
          subtitle: Text(l10n.backupScheduleEnabledSubtitle),
          onChanged: isBusy ? null : onEnabledChanged,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const ValueKey('backup_destination_field'),
          value: destinationPath.isEmpty ? null : destinationPath,
          decoration: InputDecoration(
            labelText: l10n.backupDestinationLabel,
            errorText: destinationErrorText,
            prefixIcon: const Icon(Icons.usb_outlined),
          ),
          items: [
            if (destinationPath.isNotEmpty &&
                usableDestinations.every(
                  (destination) => destination.path != destinationPath,
                ))
              DropdownMenuItem<String>(
                value: destinationPath,
                child: Text(destinationPath, overflow: TextOverflow.ellipsis),
              ),
            for (final destination in usableDestinations)
              DropdownMenuItem<String>(
                value: destination.path,
                child: Text(
                  l10n.backupDestinationOption(
                    destination.label,
                    _formatStorageBytes(context, destination.freeBytes),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: isBusy || usableDestinations.isEmpty
              ? null
              : onDestinationChanged,
        ),
        const SizedBox(height: 10),
        if (selectedDestination != null)
          PointyInlineMessage(
            icon: Icons.folder_outlined,
            compact: true,
            message: l10n.backupDestinationDetails(
              selectedDestination.backupPath,
              _formatStorageBytes(context, selectedDestination.freeBytes),
              _formatStorageBytes(context, selectedDestination.totalBytes),
            ),
          )
        else if (usableDestinations.isEmpty)
          PointyInlineMessage(
            icon: Icons.usb_off_outlined,
            compact: true,
            message: l10n.backupNoWritableDestinationsMessage,
          ),
        const SizedBox(height: 12),
        _DurationPickerTile(
          key: const ValueKey('backup_time_picker'),
          enabled: !isBusy,
          label: l10n.backupScheduledTimeLabel,
          value: scheduledTimeText,
          onTap: onPickTime ?? () {},
        ),
        const SizedBox(height: 10),
        PointyInlineMessage(
          icon: Icons.info_outline,
          compact: true,
          message: l10n.backupRetentionMessage(retentionCount),
        ),
      ],
    );
  }
}

class _BackupActionBar extends StatelessWidget {
  const _BackupActionBar({
    required this.canStartBackup,
    required this.canSaveSchedule,
    required this.isSavingSchedule,
    required this.isStartingBackup,
    required this.onSaveSchedule,
    required this.onStartBackup,
  });

  final bool canStartBackup;
  final bool canSaveSchedule;
  final bool isSavingSchedule;
  final bool isStartingBackup;
  final VoidCallback onSaveSchedule;
  final VoidCallback onStartBackup;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        OutlinedButton.icon(
          onPressed: canSaveSchedule ? onSaveSchedule : null,
          icon: isSavingSchedule
              ? const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(
            isSavingSchedule
                ? l10n.backupSavingScheduleButton
                : l10n.backupSaveScheduleButton,
          ),
        ),
        FilledButton.icon(
          onPressed: canStartBackup ? onStartBackup : null,
          icon: isStartingBackup
              ? const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                )
              : const Icon(Icons.backup_outlined),
          label: Text(
            isStartingBackup
                ? l10n.backupStartingButton
                : l10n.backupStartNowButton,
          ),
        ),
      ],
    );
  }
}

class _BackupJobProgressCard extends StatelessWidget {
  const _BackupJobProgressCard({required this.job});

  final SystemMaintenanceJob job;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final progress = (job.progressPercent.clamp(0, 100)) / 100;

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.sync, color: colors.primaryStrong),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.backupActiveJobTitle(
                      _backupOperationLabel(l10n, job.operation),
                    ),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  l10n.backupProgressPercent(job.progressPercent),
                  style: theme.textTheme.labelLarge,
                ),
              ],
            ),
            const SizedBox(height: 12),
            PointyProgressBar(value: progress),
            if (job.progressMessage.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                job.progressMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.mutedInk,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RestoreBackupFields extends StatelessWidget {
  const _RestoreBackupFields({
    required this.isBusy,
    required this.isRestoring,
    required this.onPickRestoreFile,
  });

  final bool isBusy;
  final bool isRestoring;
  final VoidCallback onPickRestoreFile;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyInlineMessage(
          icon: Icons.warning_amber_outlined,
          compact: true,
          message: l10n.restoreWarningMessage,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FilledButton.icon(
            onPressed: isBusy ? null : onPickRestoreFile,
            icon: isRestoring
                ? const SizedBox.square(
                    dimension: 18,
                    child: PointySpinner(strokeWidth: 2),
                  )
                : const Icon(Icons.upload_file_outlined),
            label: Text(
              isRestoring
                  ? l10n.restoreUploadingButton
                  : l10n.restorePickFileButton,
            ),
          ),
        ),
      ],
    );
  }
}

class _BackupJobHistory extends StatelessWidget {
  const _BackupJobHistory({
    required this.latestBackup,
    required this.latestRestore,
  });

  final SystemMaintenanceJob? latestBackup;
  final SystemMaintenanceJob? latestRestore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        _BackupJobHistoryRow(
          icon: Icons.backup_outlined,
          title: l10n.latestBackupLabel,
          job: latestBackup,
        ),
        const SizedBox(height: 8),
        _BackupJobHistoryRow(
          icon: Icons.restore_outlined,
          title: l10n.latestRestoreLabel,
          job: latestRestore,
        ),
      ],
    );
  }
}

class _BackupJobHistoryRow extends StatelessWidget {
  const _BackupJobHistoryRow({
    required this.icon,
    required this.title,
    required this.job,
  });

  final IconData icon;
  final String title;
  final SystemMaintenanceJob? job;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken.withOpacity(0.32),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(
          job == null
              ? l10n.backupNoJobValue
              : l10n.backupJobHistorySummary(
                  _backupStatusLabel(l10n, job!.status),
                  _formatOptionalBackupDateTime(context, job!.completedAt),
                  job!.backupFileName.isEmpty
                      ? l10n.shopSettingsEmptyValue
                      : job!.backupFileName,
                ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: job == null
            ? null
            : Text(
                l10n.backupProgressPercent(job!.progressPercent),
                style: theme.textTheme.labelLarge,
              ),
      ),
    );
  }
}

String _backupOperationLabel(AppLocalizations l10n, BackupOperation operation) {
  return switch (operation) {
    BackupOperation.backup => l10n.backupOperationBackup,
    BackupOperation.restore => l10n.backupOperationRestore,
    BackupOperation.unknown => l10n.shopSettingsEmptyValue,
  };
}

String _backupStatusLabel(AppLocalizations l10n, BackupJobStatus status) {
  return switch (status) {
    BackupJobStatus.queued => l10n.backupJobStatusQueued,
    BackupJobStatus.running => l10n.backupJobStatusRunning,
    BackupJobStatus.succeeded => l10n.backupJobStatusSucceeded,
    BackupJobStatus.failed => l10n.backupJobStatusFailed,
    BackupJobStatus.unknown => l10n.shopSettingsEmptyValue,
  };
}

TimeOfDay _timeOfDayFromApiValue(String value) {
  final parts = value.split(':');
  final hour = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 2 : 2;
  final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  return TimeOfDay(
    hour: hour.clamp(0, 23).toInt(),
    minute: minute.clamp(0, 59).toInt(),
  );
}

String _timeOfDayToApiValue(TimeOfDay value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute:00';
}

String _formatTimeOfDay(TimeOfDay value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _formatOptionalBackupDateTime(BuildContext context, DateTime? value) {
  if (value == null) {
    return AppLocalizations.of(context)!.shopSettingsEmptyValue;
  }
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '${value.year}-$month-$day $hour:$minute';
}

String _formatStorageBytes(BuildContext context, int bytes) {
  final l10n = AppLocalizations.of(context)!;
  if (bytes <= 0) {
    return l10n.backupStorageUnknownValue;
  }
  final gib = bytes / (1024 * 1024 * 1024);
  if (gib >= 1) {
    return l10n.backupStorageGigabytes(gib.toStringAsFixed(1));
  }
  final mib = bytes / (1024 * 1024);
  return l10n.backupStorageMegabytes(mib.toStringAsFixed(0));
}
