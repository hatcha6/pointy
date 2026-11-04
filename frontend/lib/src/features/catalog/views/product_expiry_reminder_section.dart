import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/product.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/tracking/expiry_date_field.dart';

/// «تذكير انتهاء الصلاحية» on a variant's details: a soft date to be told on,
/// for stock bought with no dates. It is not a lot and never stops a sale.
///
/// Not offered where it would mean nothing: a service, a made-to-order item,
/// or a serialised product, whose articles carry their own identity.
class ProductExpiryReminderSection extends StatefulWidget {
  const ProductExpiryReminderSection({
    super.key,
    required this.product,
    required this.capabilities,
    this.catalogRepository,
  });

  final Product product;
  final AuthorizationCapabilities capabilities;

  /// Null makes the section read-only.
  final CatalogRepository? catalogRepository;

  static bool appliesTo(Product product) =>
      product.defaultVariant != null &&
      !product.isService &&
      !product.isPrepared &&
      !product.trackingMode.tracksUnits;

  @override
  State<ProductExpiryReminderSection> createState() =>
      _ProductExpiryReminderSectionState();
}

class _ProductExpiryReminderSectionState
    extends State<ProductExpiryReminderSection> {
  late DateTime? _date = widget.product.defaultVariant?.expiryReminderDate;
  bool _saving = false;

  bool get _canEdit =>
      widget.catalogRepository != null &&
      widget.capabilities.canChangeProductVariant;

  Future<void> _save(DateTime? date) async {
    final variant = widget.product.defaultVariant;
    final repository = widget.catalogRepository;
    if (variant == null || repository == null) return;
    setState(() => _saving = true);
    final result = await repository.setVariantExpiryReminder(variant.id, date);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result case Ok(value: final saved)) {
        _date = saved.expiryReminderDate;
      }
    });
    if (result is Error<dynamic>) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.expiryReminderSaveFailed),
        ),
      );
    }
  }

  Future<void> _edit() async {
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (context) => _ReminderDateDialog(initial: _date),
    );
    if (picked != null && mounted) await _save(picked);
  }

  @override
  Widget build(BuildContext context) {
    if (!ProductExpiryReminderSection.appliesTo(widget.product)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final date = _date;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: PointyDetailSection(
        title: l10n.expiryReminderTitle,
        icon: Icons.notifications_active_outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.expiryReminderHelp,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    key: const ValueKey('expiry_reminder_value'),
                    date == null ? l10n.expiryReminderNone : formatDate(date),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: date == null ? colors.mutedInk : colors.ink,
                    ),
                  ),
                ),
                if (_saving)
                  const SizedBox.square(
                    dimension: 18,
                    child: PointySpinner(strokeWidth: 2),
                  )
                else if (_canEdit) ...[
                  if (date != null)
                    TextButton(
                      key: const ValueKey('expiry_reminder_clear'),
                      onPressed: () => _save(null),
                      child: Text(l10n.expiryReminderClearAction),
                    ),
                  FilledButton.tonal(
                    key: const ValueKey('expiry_reminder_edit'),
                    onPressed: _edit,
                    child: Text(
                      date == null
                          ? l10n.expiryReminderSetAction
                          : l10n.expiryReminderChangeAction,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReminderDateDialog extends StatefulWidget {
  const _ReminderDateDialog({this.initial});

  final DateTime? initial;

  @override
  State<_ReminderDateDialog> createState() => _ReminderDateDialogState();
}

class _ReminderDateDialogState extends State<_ReminderDateDialog> {
  late DateTime? _value = widget.initial;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.expiryReminderTitle),
      content: ExpiryDateField(
        key: const ValueKey('expiry_reminder_field'),
        value: _value,
        label: l10n.bulkTrackingReminderDateLabel,
        required: true,
        autofocus: true,
        onChanged: (date) => setState(() => _value = date),
        onSubmitted: (date) {
          if (date != null) Navigator.of(context).pop(date);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          key: const ValueKey('expiry_reminder_save'),
          onPressed: _value == null
              ? null
              : () => Navigator.of(context).pop(_value),
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }
}
