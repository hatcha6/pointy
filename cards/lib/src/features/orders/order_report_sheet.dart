import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../core/result.dart';
import '../../core/support.dart';
import '../../data/models/order.dart';
import '../../data/models/order_report.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/haptics.dart';
import '../../shared/relay_error_text.dart';

/// Asks what went wrong with [order] and files the report. Returns the report
/// the relay kept, or null when the customer backed out.
///
/// [kind] is the account's kind (`kindKey`): the reasons name what was sent
/// as the customer knows it, a player ID, a username, a Steam wallet or a
/// gift.
Future<OrderReport?> showOrderReportSheet(
  BuildContext context,
  CardOrder order, {
  required String kind,
}) => showModalBottomSheet<OrderReport>(
  context: context,
  routeSettings: screenSettings('order_report'),
  useSafeArea: true,
  isScrollControlled: true,
  builder: (_) => OrderReportSheet(order: order, kind: kind),
);

/// The words for a report's reason, for the account's [kind].
String reportReasonText(
  AppLocalizations l10n,
  ReportReason reason,
  String kind,
) => switch (reason) {
  ReportReason.notArrived => l10n.reportNotArrived(kind),
  ReportReason.wrongAccount => l10n.reportWrongAccount(kind),
  ReportReason.wrongAmount => l10n.reportWrongAmount(kind),
  ReportReason.other => l10n.reportOther,
};

IconData _reasonIcon(ReportReason reason) => switch (reason) {
  ReportReason.notArrived => Icons.hourglass_empty_rounded,
  ReportReason.wrongAccount => Icons.person_off_rounded,
  ReportReason.wrongAmount => Icons.exposure_rounded,
  ReportReason.other => Icons.help_outline_rounded,
};

/// What went wrong, in a tap, and a few words if the customer wants.
class OrderReportSheet extends StatefulWidget {
  const OrderReportSheet({super.key, required this.order, required this.kind});

  final CardOrder order;

  /// The account's kind, for the words (`kindKey`).
  final String kind;

  @override
  State<OrderReportSheet> createState() => _OrderReportSheetState();
}

class _OrderReportSheetState extends State<OrderReportSheet> {
  final _note = TextEditingController();
  ReportReason? _reason;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null || _sending) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final orders = CardsScope.of(context).orders;
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await orders.report(
      widget.order.id,
      reason: reason,
      note: _note.text,
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok(:final value):
        Haptics.success();
        Navigator.of(context).pop(value);
      case Error(:final exception):
        setState(() {
          _sending = false;
          _error = relayErrorText(l10n, exception);
        });
    }
  }

  Future<void> _whatsApp() async {
    final l10n = AppLocalizations.of(context);
    await launchUrl(
      Support.whatsAppUrl.replace(
        queryParameters: {
          'text': l10n.topUpHelpMessage(widget.kind, widget.order.id),
        },
      ),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      // Above the keyboard while the note is typed.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          CardsSpace.lg,
          CardsSpace.gutter,
          CardsSpace.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.reportTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: CardsSpace.xs),
            Text(
              l10n.reportBody,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: CardsSpace.lg),
            for (final reason in ReportReason.values)
              _ReasonTile(
                icon: _reasonIcon(reason),
                label: reportReasonText(l10n, reason, widget.kind),
                selected: _reason == reason,
                onTap: _sending
                    ? null
                    : () {
                        Haptics.select();
                        setState(() => _reason = reason);
                      },
              ),
            const SizedBox(height: CardsSpace.md),
            TextField(
              controller: _note,
              enabled: !_sending,
              maxLength: 500,
              minLines: 2,
              maxLines: 4,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                labelText: l10n.reportNote,
                hintText: l10n.reportNoteHint(widget.kind),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: CardsSpace.sm),
              Text(
                _error!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: CardsSpace.md),
            FilledButton(
              onPressed: _reason == null || _sending ? null : _send,
              child: _sending
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : Text(l10n.reportSend),
            ),
            TextButton.icon(
              onPressed: _whatsApp,
              icon: const Icon(Icons.support_agent_rounded, size: 18),
              label: Text(l10n.reportWhatsApp),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReasonTile extends StatelessWidget {
  const _ReasonTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: CardsSpace.sm),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? scheme.primaryContainer : scheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CardsRadii.card),
            side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.6 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: CardsSpace.lg,
                vertical: CardsSpace.md,
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 22,
                    color: selected
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: CardsSpace.md),
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: selected ? FontWeight.w700 : null,
                        color: selected ? scheme.onPrimaryContainer : null,
                      ),
                    ),
                  ),
                  AnimatedOpacity(
                    duration: CardsMotion.fast,
                    opacity: selected ? 1 : 0,
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: 22,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where a report stands on the order: open (we are looking), or resolved
/// with our reply.
class OrderReportCard extends StatelessWidget {
  const OrderReportCard({super.key, required this.report, required this.kind});

  final OrderReport report;

  /// The account's kind, for the reason's words (`kindKey`).
  final String kind;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final resolved = report.resolved;
    final title = resolved ? l10n.reportReplyTitle : l10n.reportOpenTitle;
    final body = resolved
        ? (report.reply.isEmpty ? l10n.reportResolvedBody : report.reply)
        : l10n.reportOpenBody(reportReasonText(l10n, report.reason, kind));
    return Container(
      padding: const EdgeInsets.all(CardsSpace.lg),
      decoration: BoxDecoration(
        color: resolved ? scheme.surface : scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(CardsRadii.card),
        boxShadow: resolved ? CardsShadows.raised : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            resolved ? Icons.mark_chat_read_rounded : Icons.flag_rounded,
            size: 22,
            color: resolved ? scheme.primary : scheme.onTertiaryContainer,
          ),
          const SizedBox(width: CardsSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: resolved ? null : scheme.onTertiaryContainer,
                  ),
                ),
                const SizedBox(height: CardsSpace.xs),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: resolved
                        ? scheme.onSurfaceVariant
                        : scheme.onTertiaryContainer,
                  ),
                ),
                if (!resolved && report.note.isNotEmpty) ...[
                  const SizedBox(height: CardsSpace.xs),
                  Text(
                    '«${report.note}»',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
