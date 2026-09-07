import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';

/// "Take me to this moment."
///
/// A date, a time, and a row of shortcuts for the answers people actually
/// want — the last hour, this morning, yesterday evening. Reviewing footage
/// almost always starts from a rough memory ("just before we closed"), so the
/// shortcuts are the primary path and the pickers are there for the case where
/// someone has a receipt in their hand and an exact minute to type.
Future<DateTime?> showCameraTimePicker(
  BuildContext context, {
  required DateTime initial,
}) {
  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CameraTimePicker(initial: initial),
  );
}

class _CameraTimePicker extends StatefulWidget {
  const _CameraTimePicker({required this.initial});

  final DateTime initial;

  @override
  State<_CameraTimePicker> createState() => _CameraTimePickerState();
}

class _CameraTimePickerState extends State<_CameraTimePicker> {
  late DateTime _moment = widget.initial.toLocal();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final now = DateTime.now();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointySectionHeader(title: l10n.cameraPlaybackPickDateAction),
            const SizedBox(height: PointyDimensions.denseGap),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _shortcut(
                  l10n.cameraJumpLastHour,
                  now.subtract(const Duration(hours: 1)),
                ),
                _shortcut(
                  l10n.cameraJumpThreeHoursAgo,
                  now.subtract(const Duration(hours: 3)),
                ),
                _shortcut(
                  l10n.cameraJumpThisMorning,
                  DateTime(now.year, now.month, now.day, 8),
                ),
                _shortcut(
                  l10n.cameraJumpYesterdayEvening,
                  DateTime(now.year, now.month, now.day - 1, 20),
                ),
              ],
            ),
            const SizedBox(height: PointyDimensions.sectionGap),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text(_dateLabel()),
                  ),
                ),
                const SizedBox(width: PointyDimensions.denseGap),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule_outlined, size: 18),
                    label: Text(_timeLabel()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: PointyDimensions.sectionGap),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_moment),
              child: Text(l10n.confirmButton),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shortcut(String label, DateTime moment) {
    return ActionChip(
      label: Text(label),
      onPressed: () => Navigator.of(context).pop(moment),
    );
  }

  String _dateLabel() {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${_moment.year}-${two(_moment.month)}-${two(_moment.day)}';
  }

  String _timeLabel() {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(_moment.hour)}:${two(_moment.minute)}';
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _moment.isAfter(now) ? now : _moment,
      // A DVR holds days to weeks, never a year — offering last January invites
      // a seek that can only come back empty.
      firstDate: now.subtract(const Duration(days: 120)),
      lastDate: now,
    );
    if (date == null || !mounted) {
      return;
    }
    setState(() {
      _moment = DateTime(
        date.year,
        date.month,
        date.day,
        _moment.hour,
        _moment.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_moment),
    );
    if (time == null || !mounted) {
      return;
    }
    setState(() {
      _moment = DateTime(
        _moment.year,
        _moment.month,
        _moment.day,
        time.hour,
        time.minute,
      );
    });
  }
}
