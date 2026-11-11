import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/models/esim.dart';
import '../../design/cards_tokens.dart';
import '../../shared/haptics.dart';

/// "512 MB", "1.5 GB": megabytes the way a data plan is sold.
String formatEsimData(int megabytes) {
  if (megabytes < 1024) {
    return '$megabytes MB';
  }
  final gigabytes = megabytes / 1024;
  final whole = gigabytes == gigabytes.roundToDouble();
  return '${gigabytes.toStringAsFixed(whole ? 0 : 1)} GB';
}

/// A figure that reads left to right inside Arabic text: data amounts, codes.
class EsimLtr extends StatelessWidget {
  const EsimLtr(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Text(text, style: style, maxLines: maxLines, overflow: overflow),
  );
}

/// A plan in one line: "3 GB · 30 يوماً". The amount keeps its own direction
/// (a "3 GB" loose in Arabic text reads "GB 3").
class EsimPlanLine extends StatelessWidget {
  const EsimPlanLine({
    super.key,
    required this.data,
    required this.days,
    required this.unlimited,
    this.style,
  });

  final String data;
  final int days;
  final bool unlimited;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Wrap(
      children: [
        if (unlimited)
          Text(l10n.esimUnlimited, style: style)
        else
          EsimLtr(data, style: style),
        if (days > 0) ...[
          Text(' · ', style: style),
          Text(l10n.esimPlanDays(days), style: style),
        ],
      ],
    );
  }
}

/// The same line as plain text, where only text fits (the checkout, a shared
/// message): isolated so the amount keeps its direction.
String esimPlanText(
  AppLocalizations l10n, {
  required String data,
  required int days,
  required bool unlimited,
}) {
  final amount = unlimited ? l10n.esimUnlimited : '\u2066$data\u2069';
  return days > 0 ? '$amount · ${l10n.esimPlanDays(days)}' : amount;
}

/// What an eSIM's state reads as.
String esimStatusText(AppLocalizations l10n, EsimStatus status) =>
    switch (status) {
      EsimStatus.notActive => l10n.esimStatusNotActive,
      EsimStatus.active => l10n.esimStatusActive,
      EsimStatus.finished => l10n.esimStatusFinished,
      EsimStatus.expired => l10n.esimStatusExpired,
      EsimStatus.unknown => l10n.esimStatusUnknown,
    };

/// A labelled value with a copy button: the manual install's details.
class EsimCopyRow extends StatelessWidget {
  const EsimCopyRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: CardsSpace.lg,
        end: CardsSpace.xs,
        top: CardsSpace.sm,
        bottom: CardsSpace.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: EsimLtr(
                    value,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.esimCopy,
            icon: const Icon(Icons.copy_rounded, size: 20),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              Haptics.select();
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text(l10n.esimCopied)));
            },
          ),
        ],
      ),
    );
  }
}

/// One note with an icon: the small print that matters.
class EsimNote extends StatelessWidget {
  const EsimNote({
    super.key,
    required this.icon,
    required this.text,
    this.color,
  });

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: tint),
        const SizedBox(width: CardsSpace.sm),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: tint),
          ),
        ),
      ],
    );
  }
}

/// What a promotion's badge says: the operator's own words, or the cut.
String esimPromoLabel(AppLocalizations l10n, EsimPromo promo) =>
    promo.badge.isNotEmpty ? promo.badge : l10n.esimPromoOff(promo.percent);
