import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../date_formatters.dart';

/// What a retracted document owes the person looking at it.
///
/// A cancelled document that says only "cancelled" invites the next question
/// and answers none of it. Every retraction in Pointy records who did it, when,
/// and the reason they gave; this turns those three into the sentence that
/// belongs under the badge — and returns null when the document is live, so a
/// caller can use it as the condition for showing anything at all.
class DocumentRetraction {
  const DocumentRetraction({
    required this.docStatus,
    this.cancelledAt,
    this.cancelledByUsername,
    this.cancelReason,
    this.amendmentIndex = 0,
  });

  final String docStatus;
  final DateTime? cancelledAt;
  final String? cancelledByUsername;
  final String? cancelReason;
  final int amendmentIndex;

  bool get isRetracted => docStatus == 'cancelled';

  /// "ألغاه أحمد في ٥ سبتمبر ١٤:٣٢ — السبب: سُجّل مرتين", as far as the
  /// record actually goes: an unattributed retraction says when but not who,
  /// and one with no reason given simply stops.
  String? sentence(AppLocalizations l10n) {
    if (!isRetracted) {
      return null;
    }
    final parts = <String>[];
    final actor = cancelledByUsername?.trim() ?? '';
    final when = cancelledAt;
    // All four combinations, because a record that is missing half of itself
    // should still say the half it has rather than drop both.
    if (when != null && actor.isNotEmpty) {
      parts.add(l10n.documentRetractedBy(actor, formatDateTime(when)));
    } else if (when != null) {
      parts.add(l10n.documentRetractedAt(formatDateTime(when)));
    } else if (actor.isNotEmpty) {
      parts.add(l10n.documentTrailActorValue(actor));
    }
    final reason = cancelReason?.trim() ?? '';
    if (reason.isNotEmpty) {
      parts.add(l10n.documentRetractedReason(reason));
    }
    // The dash binds the person to the moment; the bullet separates that
    // fact from the reason, which is a sentence of its own.
    return parts.isEmpty ? null : parts.join(' • ');
  }

  /// The retraction sentence appended to whatever the screen already says, so
  /// a callout gains the detail without gaining a second callout beside it.
  String? messageWith(AppLocalizations l10n, String? existingMessage) {
    final detail = sentence(l10n);
    final base = existingMessage?.trim() ?? '';
    if (detail == null) {
      return base.isEmpty ? null : base;
    }
    return base.isEmpty ? detail : '$base\n$detail';
  }
}
