import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/portal_payment.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

/// Which drawer took the cash for a website payment.
///
/// Open drawers and the day's closed ones alike: a shift that was counted
/// with a website top-up's cash in it shows an overage, and recording the
/// sale into it is what explains that overage. A drawer that closed before
/// the provider stamped the payment cannot have held it, and is not offered.
class PortalPaymentSessionPicker extends StatelessWidget {
  const PortalPaymentSessionPicker({
    super.key,
    required this.sessions,
    required this.paidAt,
    required this.selectedId,
    required this.onChanged,
  });

  final List<PortalPaymentSession> sessions;
  final DateTime? paidAt;
  final int? selectedId;
  final ValueChanged<int> onChanged;

  /// The drawer to start on: the only one open when the payment was made, or
  /// the only one there is. Anything less certain is the manager's choice.
  static int? suggestedFor(
    List<PortalPaymentSession> sessions,
    DateTime? paidAt,
  ) {
    final selectable = paidAt == null
        ? sessions
        : sessions.where((session) => !session.closedBefore(paidAt)).toList();
    if (paidAt != null) {
      final open = selectable
          .where((session) => session.wasOpenAt(paidAt))
          .toList();
      if (open.length == 1) return open.single.id;
    }
    return selectable.length == 1 ? selectable.single.id : null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (sessions.isEmpty) {
      return PointyInlineMessage.warning(
        message: l10n.portalPaymentsSessionNone,
      );
    }
    final selected = sessions
        .where((session) => session.id == selectedId)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final session in sessions)
          _SessionTile(
            session: session,
            paidAt: paidAt,
            selectedId: selectedId,
            onChanged: onChanged,
          ),
        if (selected != null) ..._warnings(l10n, selected),
      ],
    );
  }

  List<Widget> _warnings(AppLocalizations l10n, PortalPaymentSession session) {
    final paid = paidAt;
    return [
      if (!session.isOpen) ...[
        const SizedBox(height: 8),
        PointyInlineMessage.warning(
          key: const ValueKey('portal_payment_closed_session_warning'),
          message: l10n.portalPaymentsClosedSessionWarning,
          compact: true,
        ),
      ],
      if (paid != null &&
          session.openedAt != null &&
          paid.isBefore(session.openedAt!)) ...[
        const SizedBox(height: 8),
        PointyInlineMessage.warning(
          key: const ValueKey('portal_payment_opened_after_warning'),
          message: l10n.portalPaymentsOpenedAfterWarning,
          compact: true,
        ),
      ],
    ];
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.paidAt,
    required this.selectedId,
    required this.onChanged,
  });

  final PortalPaymentSession session;
  final DateTime? paidAt;
  final int? selectedId;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final paid = paidAt;
    final closedBefore = paid != null && session.closedBefore(paid);
    final wasOpen = paid != null && session.wasOpenAt(paid);

    final details = <String>[
      if (session.isOpen && session.openedAt != null)
        l10n.portalPaymentsSessionOpenSince(formatTime(session.openedAt!)),
      if (!session.isOpen && session.closedAt != null)
        l10n.portalPaymentsSessionClosedAt(formatDateTime(session.closedAt!)),
      if (!session.isOpen) _variance(l10n, session.cashVariance),
      if (closedBefore) l10n.portalPaymentsSessionClosedBefore,
    ];

    // groupValue/onChanged on the tile rather than a RadioGroup: the shape
    // the rest of the app uses, and one the Flutter 3.19 compat build takes.
    return RadioListTile<int>(
      key: ValueKey('portal_payment_session_${session.id}'),
      value: session.id,
      // ignore: deprecated_member_use
      groupValue: selectedId,
      // ignore: deprecated_member_use
      onChanged: closedBefore
          ? null
          : (value) {
              if (value != null) onChanged(value);
            },
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        l10n.portalPaymentsSessionTitle(
          session.sessionNumber,
          session.cashierName,
        ),
      ),
      subtitle: Text(details.join(' · ')),
      secondary: wasOpen
          ? PointyStatusPill(
              label: l10n.portalPaymentsSessionWasOpen,
              icon: Icons.schedule_outlined,
              color: colors.success,
            )
          : null,
    );
  }

  String _variance(AppLocalizations l10n, double? variance) {
    final value = variance ?? 0;
    if (value.abs() < 0.005) return l10n.portalPaymentsSessionBalanced;
    return value > 0
        ? l10n.portalPaymentsSessionOver(formatMoney(value))
        : l10n.portalPaymentsSessionShort(formatMoney(-value));
  }
}
