import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/bulk_tracking_change.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/tracking/expiry_date_field.dart';
import '../../view_models/bulk_tracking_view_model.dart';

/// «ماذا تريد؟»: where the tracking should end up, and what to do with the
/// reminder date. Both default to "no change".
class BulkTrackingOptionsSection extends StatelessWidget {
  const BulkTrackingOptionsSection({super.key, required this.viewModel});

  final BulkTrackingViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final label = Theme.of(
      context,
    ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800);
    final action = viewModel.action;
    final locked = viewModel.isApplying;

    return PointyDetailSection(
      title: l10n.bulkTrackingWhatTitle,
      icon: Icons.event_available_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.bulkTrackingTrackingLabel, style: label),
          RadioGroup<BulkTrackingTarget>(
            groupValue: action.tracking,
            onChanged: (value) {
              if (!locked && value != null) viewModel.setTracking(value);
            },
            child: Column(
              children: [
                _Choice<BulkTrackingTarget>(
                  key: const ValueKey('bulk_tracking_keep'),
                  value: BulkTrackingTarget.keep,
                  title: l10n.bulkTrackingKeep,
                ),
                _Choice<BulkTrackingTarget>(
                  key: const ValueKey('bulk_tracking_expiry'),
                  value: BulkTrackingTarget.expiry,
                  title: l10n.bulkTrackingExpiry,
                  subtitle: l10n.bulkTrackingExpiryHint,
                ),
                _Choice<BulkTrackingTarget>(
                  key: const ValueKey('bulk_tracking_lots'),
                  value: BulkTrackingTarget.lots,
                  title: l10n.bulkTrackingLots,
                  subtitle: l10n.bulkTrackingLotsHint,
                ),
              ],
            ),
          ),
          const Divider(height: 24),
          Text(l10n.bulkTrackingReminderLabel, style: label),
          RadioGroup<BulkReminderMode>(
            groupValue: action.reminderMode,
            onChanged: (value) {
              if (!locked && value != null) viewModel.setReminderMode(value);
            },
            child: Column(
              children: [
                _Choice<BulkReminderMode>(
                  key: const ValueKey('bulk_tracking_reminder_keep'),
                  value: BulkReminderMode.keep,
                  title: l10n.bulkTrackingKeep,
                ),
                _Choice<BulkReminderMode>(
                  key: const ValueKey('bulk_tracking_reminder_set'),
                  value: BulkReminderMode.set,
                  title: l10n.bulkTrackingReminderSet,
                ),
                _Choice<BulkReminderMode>(
                  key: const ValueKey('bulk_tracking_reminder_clear'),
                  value: BulkReminderMode.clear,
                  title: l10n.bulkTrackingReminderClear,
                ),
              ],
            ),
          ),
          if (action.reminderMode == BulkReminderMode.set)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 16, top: 6),
              child: ExpiryDateField(
                key: const ValueKey('bulk_tracking_reminder_date'),
                value: action.reminderDate,
                label: l10n.bulkTrackingReminderDateLabel,
                required: true,
                enabled: !locked,
                onChanged: viewModel.setReminderDate,
              ),
            ),
          const SizedBox(height: 8),
          Text(
            l10n.bulkTrackingReminderHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ),
    );
  }
}

class _Choice<T> extends StatelessWidget {
  const _Choice({
    super.key,
    required this.value,
    required this.title,
    this.subtitle,
  });

  final T value;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return RadioListTile<T>(
      value: value,
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
    );
  }
}
