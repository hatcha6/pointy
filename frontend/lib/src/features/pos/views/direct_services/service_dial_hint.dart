import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../direct_services/phone_entry.dart';
import '../../view_models/airtime_view_model.dart';

/// Said under the number field when the digits begin with the picked country's
/// own calling code — `22370123456` with Mali — which would send the credit to
/// a different number than the customer's. Never fixed by itself: one tap does.
class ServiceDialCodeHint extends StatelessWidget {
  const ServiceDialCodeHint({
    super.key,
    required this.correction,
    required this.onFix,
  });

  final DialCodeCorrection correction;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(PointyRadii.input),
        border: Border.all(color: colors.warning.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 6, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.priority_high_rounded, size: 19, color: colors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.posAirtimePhoneStartsWithDial(
                  ltrIsolated(correction.dial),
                  ltrIsolated(PhoneEntry.groupNational(correction.national)),
                ),
                style: textTheme.bodySmall?.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(width: 6),
            FilledButton.tonal(
              key: const ValueKey('service_dial_fix'),
              onPressed: onFix,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l10n.posAirtimePhoneFixDial),
            ),
          ],
        ),
      ),
    );
  }
}
