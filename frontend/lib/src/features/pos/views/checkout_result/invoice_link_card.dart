import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';

/// The sale's public link as a QR the customer scans off the screen, with
/// the link itself to copy.
///
/// When the shop publishes no links, whoever can switch it on is told what
/// it is for and where it lives, with a way straight there; anybody else is
/// shown nothing, since it is not theirs to change.
class InvoiceLinkCard extends StatefulWidget {
  const InvoiceLinkCard({
    super.key,
    required this.publicUrl,
    required this.onlineInvoicesEnabled,
    this.onOpenSettings,
  });

  final String publicUrl;
  final bool onlineInvoicesEnabled;

  /// Opens the shop settings. Null for someone who may not change them,
  /// which also hides the hint.
  final VoidCallback? onOpenSettings;

  /// Whether the card has anything to show.
  static bool showsFor({
    required String publicUrl,
    required bool onlineInvoicesEnabled,
    required bool canOpenSettings,
  }) {
    if (publicUrl.trim().isNotEmpty) {
      return true;
    }
    return !onlineInvoicesEnabled && canOpenSettings;
  }

  @override
  State<InvoiceLinkCard> createState() => _InvoiceLinkCardState();
}

class _InvoiceLinkCardState extends State<InvoiceLinkCard> {
  var _copied = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final url = widget.publicUrl.trim();

    if (url.isEmpty) {
      final onOpenSettings = widget.onOpenSettings;
      if (widget.onlineInvoicesEnabled || onOpenSettings == null) {
        return const SizedBox.shrink();
      }
      return PointyDetailCallout(
        key: const ValueKey('invoice_link_off_hint'),
        icon: Icons.qr_code_2_rounded,
        tone: PointyCalloutTone.neutral,
        title: l10n.checkoutResultLinkOffTitle,
        message: l10n.checkoutResultLinkOffBody,
        // Capped so a narrow phone with large text wraps the label instead of
        // pushing the explanation off the side.
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 112),
          child: TextButton(
            key: const ValueKey('invoice_link_open_settings'),
            onPressed: onOpenSettings,
            child: Text(
              l10n.checkoutResultLinkOffAction,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return DecoratedBox(
      key: const ValueKey('invoice_link_card'),
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(PointyRadii.input),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // Dark on light whatever the till's theme: the customer's camera
            // is the reader, and many will not read an inverted code.
            Theme(
              data: PointyTheme.light(),
              child: Builder(
                builder: (context) => DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.pointyColors.surface,
                    borderRadius: BorderRadius.circular(PointyRadii.card),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: PointyQrImage(
                      data: url,
                      size: 112,
                      semanticsLabel: l10n.checkoutResultLinkTitle,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.checkoutResultLinkTitle,
                    style: textTheme.titleSmall?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.checkoutResultLinkBody,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextButton.icon(
                    key: const ValueKey('invoice_link_copy'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (mounted) setState(() => _copied = true);
                    },
                    icon: Icon(
                      _copied ? Icons.check_rounded : Icons.copy_rounded,
                      size: 18,
                    ),
                    label: Text(
                      _copied
                          ? l10n.publicInvoiceUrlCopiedMessage
                          : l10n.copyPublicInvoiceUrlButton,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
