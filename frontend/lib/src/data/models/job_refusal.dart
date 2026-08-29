import '../services/api_session.dart';

/// Why the backend refused a job action, when it refused for a reason the app
/// can act on rather than merely report.
///
/// Two of the operations guards are *decisions*, not mistakes: handing a phone
/// back before it is paid for, and billing more than the customer agreed to.
/// Both are legitimate sometimes, so the backend answers them with a `code` and
/// the numbers involved, and the app turns each into a specific question —
/// "invoice it first?" or "the customer approved 100, this is 150; are they
/// happy?" — instead of a red line that just says no.
enum JobRefusalKind {
  /// The job must be invoiced and settled before its property can be released.
  settlementRequired,

  /// The invoice total is above [approvedPrice].
  overApprovedPrice,

  unknown,
}

class JobRefusal {
  const JobRefusal({
    required this.kind,
    this.detail = '',
    this.approvedPrice = '',
    this.invoiceTotal = '',
  });

  final JobRefusalKind kind;

  /// The backend's own sentence. Used only as a fallback: each known kind has a
  /// localized dialog of its own that reads better than a translated string
  /// from an API.
  final String detail;
  final String approvedPrice;
  final String invoiceTotal;
}

/// The structured refusal carried by a rejected job action, or null when the
/// failure was something else (a network drop, a permission denial, a 500).
JobRefusal? jobRefusalFromException(Object error) {
  if (error is! PosApiException || error.statusCode != 400) {
    return null;
  }
  final decoded = error.decodedBody;
  if (decoded is! Map<String, Object?>) {
    return null;
  }
  final kind = switch (decoded['code']?.toString()) {
    'settlement_required' => JobRefusalKind.settlementRequired,
    'over_approved_price' => JobRefusalKind.overApprovedPrice,
    _ => JobRefusalKind.unknown,
  };
  if (kind == JobRefusalKind.unknown) {
    return null;
  }
  return JobRefusal(
    kind: kind,
    detail: decoded['detail']?.toString() ?? '',
    approvedPrice: decoded['approved_price']?.toString() ?? '',
    invoiceTotal: decoded['invoice_total']?.toString() ?? '',
  );
}
