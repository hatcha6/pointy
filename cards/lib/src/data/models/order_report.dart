import 'json.dart';

/// What a customer can say went wrong with an order.
enum ReportReason {
  notArrived('not_arrived'),
  wrongAccount('wrong_account'),
  wrongAmount('wrong_amount'),
  other('other');

  const ReportReason(this.wire);

  /// As the relay names it.
  final String wire;

  static ReportReason parse(String raw) =>
      values.where((r) => r.wire == raw).firstOrNull ?? other;
}

/// A customer's report about one of their orders, and our reply to it.
class OrderReport {
  const OrderReport({
    required this.id,
    required this.reason,
    required this.note,
    required this.resolved,
    required this.reply,
    this.createdAt,
    this.resolvedAt,
  });

  factory OrderReport.fromJson(Map<String, dynamic> json) => OrderReport(
    id: readString(json, 'id'),
    reason: ReportReason.parse(readString(json, 'reason')),
    note: readString(json, 'note'),
    resolved: readString(json, 'status') == 'resolved',
    reply: readString(json, 'reply'),
    createdAt: readTime(json, 'created_at'),
    resolvedAt: readTime(json, 'resolved_at'),
  );

  final String id;
  final ReportReason reason;

  /// The customer's own words, if any.
  final String note;

  /// Looked at: [reply] is what we answered (may be empty).
  final bool resolved;
  final String reply;
  final DateTime? createdAt;
  final DateTime? resolvedAt;
}
