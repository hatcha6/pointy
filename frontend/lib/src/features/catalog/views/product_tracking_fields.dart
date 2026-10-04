import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/customer_asset.dart';
import '../../../data/models/identified_stock_settings.dart';
import '../../../data/models/product_tracking.dart';
import '../../../data/models/tracking_mode.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/tracking/tracking_features.dart';
import '../../../shared/tracking/tracking_labels.dart';

/// How a product's stock is identified, and the facts each way reads.
///
/// Shown only once the shop has switched serial or lot tracking on (see
/// [TrackingFeatures]); until then the forms keep the single «يتابع تاريخ
/// الانتهاء» switch they always had, and a grocer sees nothing new.
///
/// Choosing a mode is guarded rather than free — it re-labels the history of
/// whatever is already on the shelf — so for a product that exists, a change
/// says so under the choice, and the server's refusal (stock on hand) lands on
/// [errorText] in the server's own words.
class ProductTrackingFields extends StatefulWidget {
  const ProductTrackingFields({
    super.key,
    required this.value,
    required this.onChanged,
    required this.features,
    this.savedMode,
    this.assetTypes = const [],
    this.assetTypesLoading = false,
    this.assetTypesFailed = false,
    this.onReloadAssetTypes,
    this.doesNotKeepStock = false,
    this.errorText,
    this.enabled = true,
  });

  final ProductTracking value;
  final ValueChanged<ProductTracking> onChanged;
  final TrackingFeatures features;

  /// The mode the product is saved with; null while it is being created.
  final TrackingMode? savedMode;

  /// The kinds of identified thing a shop registers — phone, vehicle, laptop —
  /// the same list its workshop intake uses.
  final List<CustomerAssetType> assetTypes;
  final bool assetTypesLoading;
  final bool assetTypesFailed;
  final VoidCallback? onReloadAssetTypes;

  /// A service or a made-to-order dish has no shelf, so nothing on it can be
  /// identified: the choice is shown, explained and locked to quantity.
  final bool doesNotKeepStock;

  /// The server's refusal of a mode change, already in Arabic.
  final String? errorText;
  final bool enabled;

  @override
  State<ProductTrackingFields> createState() => _ProductTrackingFieldsState();
}

class _ProductTrackingFieldsState extends State<ProductTrackingFields> {
  late final TextEditingController _warrantyController;

  @override
  void initState() {
    super.initState();
    _warrantyController = TextEditingController(
      text: _days(widget.value.warrantyDays),
    );
  }

  @override
  void didUpdateWidget(covariant ProductTrackingFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A value set from outside — a copied product, a carried run — reaches
    // the box; one that merely echoes what was typed leaves the cursor be.
    final typed = int.tryParse(_warrantyController.text.trim()) ?? 0;
    if (typed != widget.value.warrantyDays) {
      _warrantyController.text = _days(widget.value.warrantyDays);
    }
  }

  @override
  void dispose() {
    _warrantyController.dispose();
    super.dispose();
  }

  static String _days(int days) => days <= 0 ? '' : '$days';

  void _emit(ProductTracking next) {
    if (next != widget.value) {
      widget.onChanged(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final value = widget.value;
    final mode = value.mode;
    final enabled = widget.enabled && !widget.doesNotKeepStock;
    final modes = widget.features.offeredModes(
      current: widget.savedMode ?? mode,
    );
    final changesSavedMode =
        widget.savedMode != null && widget.savedMode != mode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: spacing.sm,
          runSpacing: spacing.sm,
          children: [
            for (final option in modes)
              ChoiceChip(
                key: ValueKey('product_tracking_mode_${option.wire}'),
                // The mode's own icon stays: the filled chip already says
                // which is chosen, and a check over it hid what it was.
                showCheckmark: false,
                avatar: Icon(trackingModeIcon(option), size: 18),
                label: Text(trackingModeLabel(l10n, option)),
                selected: option == mode,
                onSelected: enabled
                    ? (_) => _emit(value.copyWith(mode: option))
                    : null,
              ),
          ],
        ),
        SizedBox(height: spacing.sm),
        Text(
          widget.doesNotKeepStock
              ? l10n.productTrackingNoStock
              : trackingModeDescription(l10n, mode),
          style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        if (changesSavedMode) ...[
          SizedBox(height: spacing.sm),
          PointyInlineMessage.warning(
            key: const ValueKey('product_tracking_change_warning'),
            message: l10n.productTrackingChangeWarning,
            icon: Icons.history_toggle_off_outlined,
            compact: true,
          ),
        ],
        if (widget.errorText case final error?) ...[
          SizedBox(height: spacing.sm),
          PointyInlineMessage.error(
            key: const ValueKey('product_tracking_error'),
            message: error,
            compact: true,
          ),
        ],
        if (mode.tracksUnits && !widget.doesNotKeepStock) ...[
          SizedBox(height: spacing.md),
          ResponsiveFormGrid(
            maxColumns: 2,
            children: [
              _assetTypeField(l10n),
              TextField(
                key: const ValueKey('product_tracking_warranty'),
                controller: _warrantyController,
                enabled: enabled,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (text) => _emit(
                  value.copyWith(warrantyDays: int.tryParse(text.trim()) ?? 0),
                ),
                decoration: InputDecoration(
                  labelText: l10n.productTrackingWarrantyLabel,
                  helperText: l10n.productTrackingWarrantyHelper,
                  prefixIcon: const Icon(Icons.verified_user_outlined),
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          PointyInlineMessage(
            message: l10n.productTrackingVariantOrUnitHint,
            icon: Icons.lightbulb_outline,
            compact: true,
          ),
        ],
        // What the server acts on for a lot: which leaves first, and whether
        // an expired one may leave at all. The shelf life and warning days the
        // product also stores are carried through untouched — nothing reads
        // them yet, and a box that changes nothing is worse than no box.
        if (mode.tracksLots && !widget.doesNotKeepStock) ...[
          SizedBox(height: spacing.md),
          ResponsiveFormGrid(
            maxColumns: 2,
            children: [
              DropdownButtonFormField<BatchPickStrategy>(
                key: ValueKey(
                  'product_tracking_pick_${value.autoPickStrategy.wire}',
                ),
                initialValue: value.autoPickStrategy,
                decoration: InputDecoration(
                  labelText: l10n.batchPickStrategyLabel,
                  prefixIcon: const Icon(Icons.sort_outlined),
                ),
                items: [
                  for (final strategy in BatchPickStrategy.values)
                    DropdownMenuItem(
                      value: strategy,
                      child: Text(batchPickStrategyLabel(l10n, strategy)),
                    ),
                ],
                onChanged: enabled
                    ? (strategy) {
                        if (strategy != null) {
                          _emit(value.copyWith(autoPickStrategy: strategy));
                        }
                      }
                    : null,
              ),
            ],
          ),
          SwitchListTile(
            key: const ValueKey('product_tracking_prevent_expired'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.productTrackingPreventExpiredLabel),
            subtitle: Text(l10n.productTrackingPreventExpiredHelper),
            value: value.preventSellingExpired,
            onChanged: enabled
                ? (prevent) =>
                      _emit(value.copyWith(preventSellingExpired: prevent))
                : null,
          ),
        ],
      ],
    );
  }

  Widget _assetTypeField(AppLocalizations l10n) {
    final value = widget.value;
    final types = widget.assetTypes;
    if (widget.assetTypesFailed) {
      return PointyInlineMessage.error(
        message: l10n.productTrackingAssetTypesFailed,
        compact: true,
        trailing: widget.onReloadAssetTypes == null
            ? null
            : TextButton(
                onPressed: widget.onReloadAssetTypes,
                child: Text(l10n.retryButton),
              ),
      );
    }
    final known = types.any((type) => type.id == value.assetTypeId);
    return DropdownButtonFormField<int?>(
      key: ValueKey(
        'product_tracking_asset_type_${value.assetTypeId}_${types.length}',
      ),
      // A type the list has not loaded yet (or that was deactivated) is kept,
      // not cleared: an unknown id shows as unset until the list arrives.
      initialValue: known ? value.assetTypeId : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: l10n.productTrackingAssetTypeLabel,
        helperText: l10n.productTrackingAssetTypeHelper,
        helperMaxLines: 2,
        prefixIcon: const Icon(Icons.devices_other_outlined),
        suffixIcon: widget.assetTypesLoading
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox.square(
                  dimension: 16,
                  child: PointySpinner(strokeWidth: 2),
                ),
              )
            : null,
      ),
      items: [
        DropdownMenuItem<int?>(
          value: null,
          child: Text(l10n.productTrackingAssetTypeNone),
        ),
        for (final type in types)
          if (type.isActive || type.id == value.assetTypeId)
            DropdownMenuItem<int?>(
              value: type.id,
              child: Text(type.name, overflow: TextOverflow.ellipsis),
            ),
      ],
      onChanged: widget.enabled && !widget.doesNotKeepStock
          ? (id) => _emit(value.copyWith(assetTypeId: id))
          : null,
    );
  }
}
