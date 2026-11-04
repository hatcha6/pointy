import 'package:flutter/material.dart';

import '../design/design.dart';

/// One of a line's tracked-goods captures — expiry, lots, serials — as a chip
/// that says whether the line still owes it.
///
/// Shared by the counter purchase and the purchase order, so a lot looks and
/// behaves the same wherever it is typed. [owed] paints it red (the line
/// cannot go without it); [done] paints it green; neither is the quiet,
/// optional state.
///
/// [expanded] draws it as a full-width row the height and shape of a text
/// field, for a form where it sits under one (the purchase order line); the
/// counter purchase keeps the compact chip that wraps beside its others.
class TrackingCaptureChip extends StatelessWidget {
  const TrackingCaptureChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.owed = false,
    this.done = false,
    this.expanded = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool owed;
  final bool done;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final tone = owed
        ? colors.danger
        : done
        ? colors.primaryStrong
        : colors.mutedInk;
    final iconWidget = Icon(
      done ? Icons.check_circle_outline : icon,
      size: 20,
      color: tone,
    );
    if (expanded) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
            alignment: AlignmentDirectional.centerStart,
            backgroundColor: colors.surface,
            foregroundColor: owed ? colors.danger : colors.ink,
            side: BorderSide(color: owed ? colors.danger : colors.line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PointyRadii.input),
            ),
          ),
          child: Row(
            children: [
              iconWidget,
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: owed ? colors.danger : colors.ink,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: colors.mutedInk),
            ],
          ),
        ),
      );
    }
    return ActionChip(
      visualDensity: VisualDensity.compact,
      avatar: iconWidget,
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: owed ? colors.danger : colors.ink,
      ),
      side: BorderSide(color: owed ? colors.danger : colors.line),
      backgroundColor: colors.surface,
      onPressed: onPressed,
    );
  }
}
