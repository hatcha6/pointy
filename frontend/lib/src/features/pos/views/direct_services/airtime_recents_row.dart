import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/service_quote.dart';
import '../../../../data/models/services_directory.dart';
import '../../../../shared/design/design.dart';
import '../../direct_services/foreign_amount.dart';
import '../../direct_services/phone_entry.dart';
import '../../view_models/services_catalog.dart';
import 'service_flag.dart';
import 'service_text_scale.dart';
import 'wheel_scroll_row.dart';

/// The numbers sold to lately, one chip each — flag, number, network, last
/// amount — so a repeat customer is one tap.
class AirtimeRecentsRow extends StatelessWidget {
  const AirtimeRecentsRow({
    super.key,
    required this.recents,
    required this.catalog,
    required this.onSelected,
  });

  final List<RecentRecipient> recents;
  final ServicesCatalog catalog;
  final ValueChanged<RecentRecipient> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    if (recents.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: textBoundExtent(context, 46),
      child: Row(
        children: [
          Tooltip(
            message: l10n.posAirtimeRecentTitle,
            child: Icon(
              Icons.history_rounded,
              size: 20,
              color: colors.mutedInk,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: WheelScrollRow(
              fadeEdges: true,
              child: Row(
                children: [
                  for (final (index, recipient) in recents.indexed) ...[
                    if (index > 0) const SizedBox(width: 8),
                    _RecentChip(
                      key: ValueKey('service_recent_${recipient.phone}'),
                      recipient: recipient,
                      catalog: catalog,
                      onTap: () => onSelected(recipient),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentChip extends StatelessWidget {
  const _RecentChip({
    super.key,
    required this.recipient,
    required this.catalog,
    required this.onTap,
  });

  final RecentRecipient recipient;
  final ServicesCatalog catalog;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final country = catalog.directory?.country(recipient.country);
    final number = _display(country, recipient.phone);
    final amount = recipient.amount.isEmpty
        ? ''
        : formatForeignAmountText(recipient.amount);
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.input),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ServiceFlag(code: recipient.country),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    number,
                    textDirection: TextDirection.ltr,
                    style: PointyTypography.numeric(
                      (textTheme.labelLarge ?? const TextStyle()).copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    [
                      if (recipient.operatorName.isNotEmpty)
                        recipient.operatorName,
                      if (amount.isNotEmpty) amount,
                    ].join(' · '),
                    maxLines: 1,
                    style: textTheme.labelSmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _display(ServiceCountry? country, String phone) {
    if (country == null) {
      return phone;
    }
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    for (final dial in country.dial) {
      if (digits.startsWith(dial) && digits.length > dial.length) {
        return PhoneEntry.display(
          dial: dial,
          national: digits.substring(dial.length),
        );
      }
    }
    return phone;
  }
}
