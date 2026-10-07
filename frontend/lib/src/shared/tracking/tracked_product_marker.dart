import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/tracking_mode.dart';
import '../design/design.dart';
import 'tracking_labels.dart';

/// How a product's stock is identified, as a small flag on its catalog card.
///
/// A buyer adding three iPhone variants should see that each handset will be
/// scanned at receipt *before* ordering, not discover it when the receiving
/// dialog asks. Lots of goods that never expire say «دفعات» rather than the
/// mode's own «دفعات وصلاحية», because a paint batch has no date to give.
class TrackedProductMarker extends StatelessWidget {
  const TrackedProductMarker({
    super.key,
    required this.mode,
    this.expiryRequired = false,
  });

  final TrackingMode mode;
  final bool expiryRequired;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final label = mode == TrackingMode.batch && !expiryRequired
        ? l10n.productTileTrackingLots
        : trackingModeLabel(l10n, mode);
    return Tooltip(
      message: trackingModeDescription(l10n, mode),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(trackingModeIcon(mode), size: 14, color: colors.primaryDark),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.primaryDark,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
